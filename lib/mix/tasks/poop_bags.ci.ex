defmodule Mix.Tasks.PoopBags.Ci do
  @shortdoc "Scan a project, diff against a baseline, gate on regressions"

  @moduledoc """
  The CI face of poop_bags: scan a project synchronously, diff the result
  against a baseline scan, and exit non-zero when new violations or
  regressions appear.

      mix poop_bags.ci --path /abs/path/to/project
      mix poop_bags.ci --path . --against 12 --threshold 30
      mix poop_bags.ci --path . --format json --out poop_bags_report.json

  ## Options

  * `--path` (required) — project directory to scan
  * `--against` — baseline scan id, or `latest` (default: the most recent
    finished scan of the same project; `none` skips the diff). An explicit ID
    must identify a finished, unexpired scan; invalid or unavailable IDs fail.
  * `--threshold` — CRAP strictly above this is a violation (overrides
    `.poopbags.json`)
  * `--coverage-report` — path to an LCOV or ExCoveralls JSON report
    (overrides `.poopbags.json`); an unusable report FAILS the scan here,
    unlike the web flow
  * `--label` — label for the scan row
  * `--format` — `markdown` (default) or `json`
  * `--out` — also write the report to this file
  * `--max-rows` — display rows shown in the report (default 25); never limits the gate

  Exit codes: `0` gate passed (or no baseline), `1` gate failed,
  `2` the scan or requested comparison failed.

  The scan lands in the same SQLite ledger the web UI reads, so a CI run and
  a web run produce the same explained result.
  """

  use Mix.Task

  alias PoopBags.Catalog
  alias PoopBags.Diff

  @requirements ["app.start"]

  @switches [
    path: :string,
    against: :string,
    threshold: :float,
    coverage_report: :string,
    label: :string,
    format: :string,
    out: :string,
    max_rows: :integer
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _parsed, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] or !opts[:path] do
      Mix.raise(
        "usage: mix poop_bags.ci --path DIR [--against latest|ID|none] " <>
          "[--threshold N] [--coverage-report FILE] [--format markdown|json] [--out FILE]"
      )
    end

    Application.ensure_all_started(:poop_bags)

    attrs =
      %{"project_path" => opts[:path], "label" => opts[:label] || "ci"}
      |> maybe_put("threshold", opts[:threshold])

    with {:ok, scan} <- Catalog.create_scan(attrs),
         {:ok, scan} <-
           PoopBags.Engine.run(scan,
             strict_coverage: true,
             coverage_report: opts[:coverage_report]
           ) do
      if scan.files_failed > 0 do
        Mix.shell().error(
          "poop_bags: scan failed: #{scan.files_failed} file(s) could not be analyzed; partial results retained in scan ##{scan.id}"
        )

        exit({:shutdown, 2})
      end

      baseline = resolve_baseline(scan, opts[:against])
      diff = baseline && diff_for(baseline, scan, opts)

      report = render(scan, baseline, diff, opts)

      if out = opts[:out], do: File.write!(out, report)
      Mix.shell().info(report)

      announce_gate(diff, baseline)
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        Mix.shell().error("poop_bags: invalid scan: #{inspect(changeset.errors)}")
        exit({:shutdown, 2})

      {:error, reason} ->
        Mix.shell().error("poop_bags: scan failed: #{reason}")
        exit({:shutdown, 2})
    end
  end

  defp announce_gate(nil, _baseline) do
    Mix.shell().info("\npoop_bags: no baseline — first scan recorded. Gate: PASS")
    :ok
  end

  defp announce_gate(%{comparable: false} = diff, _baseline) do
    Mix.shell().error("poop_bags: comparison failed: " <> Enum.join(diff.warnings, "; "))
    exit({:shutdown, 2})
  end

  defp announce_gate(diff, baseline) do
    if Diff.gate_passed?(diff) do
      Mix.shell().info("\npoop_bags: gate PASS (baseline scan ##{baseline.id})")
      :ok
    else
      Mix.shell().error(
        "\npoop_bags: gate FAIL — new violations or regressions vs scan ##{baseline.id}"
      )

      exit({:shutdown, 1})
    end
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  defp resolve_baseline(_scan, "none"), do: nil
  defp resolve_baseline(scan, "latest"), do: Catalog.latest_baseline(scan)
  defp resolve_baseline(scan, nil), do: Catalog.latest_baseline(scan)

  defp resolve_baseline(_scan, id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} when int_id > 0 and int_id <= 9_223_372_036_854_775_807 ->
        case Catalog.get_scan(int_id) do
          nil ->
            baseline_error("baseline scan ##{int_id} not found")

          %Catalog.Scan{details_expired_at: expired} when not is_nil(expired) ->
            baseline_error("baseline scan ##{int_id} details expired by retention")

          %Catalog.Scan{status: status} when status != "done" ->
            baseline_error("baseline scan ##{int_id} has not finished (status #{status})")

          baseline ->
            baseline
        end

      _ ->
        baseline_error(
          "invalid baseline #{inspect(id)}; expected a positive scan ID, latest or none"
        )
    end
  end

  defp baseline_error(message) do
    Mix.shell().error("poop_bags: comparison failed: " <> message)
    exit({:shutdown, 2})
  end

  defp diff_for(baseline, scan, opts) do
    Diff.between(baseline, scan, limit: opts[:max_rows] || 25)
  end

  # ---------------------------------------------------------------- report

  defp render(scan, nil, _diff, opts) do
    if opts[:format] == "json", do: summary_json(scan), else: summary_markdown(scan)
  end

  defp render(scan, _baseline, diff, opts) do
    if opts[:format] == "json" do
      json_report(scan, diff)
    else
      markdown_report(scan, diff)
    end
  end

  defp summary_markdown(scan) do
    """
    # poop_bags — scan ##{scan.id}

    #{files_line(scan)}
    functions: #{scan.functions_total} · worst CRAP: #{scan.worst_crap} · threshold: #{threshold(scan)}
    coverage: #{coverage_line(scan)}
    policy: `#{scan.stats["policy"]}`

    #{provenance_markdown(scan)}
    """
  end

  defp summary_json(scan) do
    Jason.encode!(%{
      scan_id: scan.id,
      baseline_id: nil,
      threshold: threshold(scan),
      gate_passed: true,
      files: %{
        done: scan.files_done,
        total: scan.files_total,
        failed: scan.files_failed,
        skipped: scan.files_skipped
      },
      functions_total: scan.functions_total,
      worst_crap: scan.worst_crap,
      policy: scan.stats["policy"],
      parsers: scan.stats["parsers"] || [],
      analyzer_skips: scan.stats["analyzer_skips"] || []
    })
  end

  defp markdown_report(_scan, diff) do
    s = diff.summary

    rows =
      Enum.map_join(diff.rows, "\n", fn row ->
        outcome = row.outcome
        id = row.identity
        {lang, path, module, fun} = id
        where = if module == "", do: fun, else: "#{module}.#{fun}"

        movement =
          cond do
            row.baseline && row.current ->
              " (#{row.baseline.crap} → #{row.current.crap}, Δ#{row.delta_crap})"

            row.baseline ->
              " (was #{row.baseline.crap})"

            true ->
              " (new: #{row.current.crap})"
          end

        where_line = if row.current, do: "#{path}:#{row.current.line}", else: path
        marker = if row.violation, do: " ⚠️", else: ""
        "- **#{outcome}**#{marker} `#{lang}` `#{where}` — #{where_line}#{movement}"
      end)

    """
    # poop_bags — scan ##{diff.current.id} vs baseline ##{diff.baseline.id}

    #{files_line(diff.current)}
    threshold: #{threshold(diff.current)} · coverage: #{coverage_line(diff.current)}
    policy: `#{diff.current.stats["policy"]}`

    #{provenance_markdown(diff.current)}

    Outcomes: introduced #{s.introduced} · regressed #{s.regressed} · resolved #{s.resolved} · improved #{s.improved} · removed #{s.removed} · unchanged #{s.unchanged}

    #{warnings(diff)}
    #{rows}
    """
  end

  defp provenance_markdown(scan) do
    parsers =
      case scan.stats["parsers"] || [] do
        [] ->
          "Parser provenance: none recorded."

        entries ->
          "Parser provenance:\n" <>
            Enum.map_join(entries, "\n", fn parser ->
              "- `#{parser["parser"]}` #{parser["parser_version"]} · shared parser #{parser["package_version"]} · `#{parser["policy"]}`"
            end)
      end

    exclusions =
      case scan.stats["analyzer_skips"] || [] do
        [] ->
          "Excluded source expressions: none."

        entries ->
          "Excluded source expressions:\n" <>
            Enum.map_join(entries, "\n", fn exclusion ->
              detail =
                if exclusion["reason"] == "module_scope",
                  do: " (outside reported functions)",
                  else: ""

              "- `#{exclusion["path"]}`: `#{exclusion["reason"]}`#{detail}"
            end)
      end

    parsers <> "\n\n" <> exclusions
  end

  defp warnings(%Diff{warnings: []}), do: ""

  defp warnings(%Diff{warnings: warnings}) do
    "Warnings (comparability):\n" <> Enum.map_join(warnings, "\n", &"- #{&1}") <> "\n"
  end

  defp json_report(scan, diff) do
    Jason.encode!(%{
      scan_id: scan.id,
      baseline_id: diff.baseline.id,
      threshold: threshold(scan),
      policy: scan.stats["policy"],
      parsers: scan.stats["parsers"] || [],
      analyzer_skips: scan.stats["analyzer_skips"] || [],
      comparable: diff.comparable,
      warnings: diff.warnings,
      summary: diff.summary,
      gate_passed: Diff.gate_passed?(diff),
      rows:
        Enum.map(diff.rows, fn row ->
          {language, path, module, function} = row.identity

          %{
            outcome: row.outcome,
            violation: row.violation,
            language: language,
            path: path,
            module: module,
            function: function,
            baseline_crap: row.baseline && row.baseline.crap,
            current_crap: row.current && row.current.crap,
            delta_crap: row.delta_crap,
            delta_complexity: row.delta_complexity,
            coverage: row.current && row.current.coverage,
            coverage_source: row.current && row.current.coverage_source
          }
        end)
    })
  end

  defp files_line(scan) do
    "files: #{scan.files_done}/#{scan.files_total} · failed #{scan.files_failed} · skipped #{scan.files_skipped}"
  end

  defp threshold(scan), do: scan.threshold || 20.0

  defp coverage_line(scan) do
    case scan.stats["coverage"] do
      %{"measured_functions" => m, "assumed_functions" => a} ->
        "measured for #{m} functions, assumed for #{a}"

      _ ->
        "all assumed (#{round((scan.assumed_coverage || 0.0) * 100)}%)"
    end
  end
end
