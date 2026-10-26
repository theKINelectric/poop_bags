defmodule PoopBags.Engine do
  @moduledoc """
  The scan engine: one place where a scan actually happens, shared by the web
  `ScanRunner` and the `mix poop_bags.ci` task.

  Responsibilities, in order:

  1. Resolve the effective project configuration (`.poopbags.json` merged
     with the invocation's overrides) and persist its snapshot + digest.
  2. Walk the project with the config's exclusions and language filter.
  3. Ingest the configured coverage report (LCOV or ExCoveralls JSON), if
     any — an unusable report either fails the scan (`strict_coverage: true`,
     CI) or proceeds assumed-only with a recorded warning (web).
  4. Drive every file through the `PoopBags.ScanPipeline` FlowExtra belt
     from an unlinked task pool, hashing each file for the manifest.
  5. Commit findings, the file manifest, and the finished summary in one
     transaction.

  Progress (`files_done`) is written to the scan row in throttled bumps so
  polling pages can watch the belts.
  """

  alias PoopBags.Catalog
  alias PoopBags.Coverage
  alias PoopBags.ProjectConfig
  alias PoopBags.ScanPipeline
  alias PoopBags.Walker

  @caller_pool 12
  @per_file_timeout 120_000
  @task_timeout 180_000
  @progress_every 50

  @doc """
  Runs `scan` to completion, synchronously in the caller's process.

  Options:

  * `:coverage_report` — path override for the coverage report (CLI flag)
  * `:strict_coverage` — fail the scan on an unusable report (CI default)
  * `:caller_pool` — task pool size override
  * `:per_file_timeout` — per-file pipeline call timeout override (testing)

  Returns `{:ok, scan}` with the reloaded finished row, or `{:error, reason}`
  with the row already marked errored.
  """
  @spec run(Catalog.Scan.t(), keyword()) :: {:ok, Catalog.Scan.t()} | {:error, String.t()}
  def run(%Catalog.Scan{} = scan, opts \\ []) do
    with {:ok, config} <- prepare_config(scan, opts),
         {:ok, coverage} <- ingest_coverage(scan, config, opts),
         {:ok, scan, files} <- mark_running(scan, config) do
      started = System.monotonic_time(:millisecond)

      acc =
        run_belt(scan.id, files, aligned_coverage(coverage, files), scan.assumed_coverage, opts)
        |> Map.put(:belt_ms, System.monotonic_time(:millisecond) - started)

      finalize(acc, scan, config)
    end
  end

  # ------------------------------------------------------------ preparation

  defp prepare_config(scan, opts) do
    overrides =
      %{"threshold" => scan.threshold, "coverage_report" => opts[:coverage_report]}
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    ProjectConfig.load(scan.project_path, overrides)
  end

  defp ingest_coverage(_scan, %ProjectConfig{coverage_report: nil}, _opts), do: {:ok, nil}

  defp ingest_coverage(scan, %ProjectConfig{} = config, opts) do
    case Coverage.parse_file(config.coverage_report) do
      {:ok, lines, format} ->
        {:ok, %{lines: lines, format: format, raw: true}}

      {:error, reason} ->
        if opts[:strict_coverage] do
          Catalog.fail_scan(scan, "coverage report unusable: #{reason}")
          {:error, "coverage report unusable: #{reason}"}
        else
          Catalog.note_coverage_warning(scan.id, reason)
          {:ok, nil}
        end
    end
  end

  # Reports built elsewhere carry absolute paths; align them onto the
  # project's real files before the belt sees them.
  defp aligned_coverage(nil, _files), do: nil

  defp aligned_coverage(%{lines: lines} = coverage, %{files: files}) do
    %{coverage | lines: Coverage.align(lines, Enum.map(files, & &1.rel_path)), raw: false}
  end

  defp mark_running(scan, config) do
    {files, skipped} = Walker.collect(scan.project_path, config)

    scan =
      Catalog.mark_running(scan, %{
        files_total: length(files),
        config: ProjectConfig.snapshot(config),
        threshold: config.threshold
      })

    {:ok, scan, %{files: files, skipped: skipped}}
  end

  # ------------------------------------------------------------ the belt

  defp run_belt(scan_id, %{files: entries, skipped: skipped}, coverage, assumed, opts) do
    pipeline =
      ScanPipeline.start(%{
        coverage: assumed,
        line_coverage: coverage && coverage.lines
      })

    acc = %{done: 0, failed: 0, progress_marker: 0, ips: [], walker_skipped: 0}

    result =
      try do
        # nolink, under a supervisor: a caller task that dies (admission
        # error, pipeline timeout) arrives as {:exit, reason} instead of
        # taking this process down with it. One bad file stays one bad file.
        # zip_input_on_exit keeps the file's identity on that path, so a lost
        # file still lands in the manifest (hash "unknown") instead of a
        # nil-path row that would fail the whole commit.
        Task.Supervisor.async_stream_nolink(
          PoopBags.CallerSupervisor,
          entries,
          &ScanPipeline.call(
            pipeline,
            ScanPipeline.ip_for(&1),
            opts[:per_file_timeout] || @per_file_timeout
          ),
          ordered: false,
          max_concurrency: opts[:caller_pool] || @caller_pool,
          timeout: @task_timeout,
          zip_input_on_exit: true
        )
        |> Enum.reduce(acc, fn
          {:ok, ip}, acc ->
            acc =
              %{acc | ips: [ip | acc.ips], done: acc.done + 1}
              |> then(&%{&1 | failed: &1.failed + failed_bump(ip)})

            maybe_report_progress(scan_id, acc)

          # zip_input_on_exit shapes exits as {:exit, {entry, reason}} — the
          # file's identity survives the crash.
          {:exit, {entry, reason}}, acc ->
            acc = %{
              acc
              | ips: [lost_ip(reason, entry) | acc.ips],
                done: acc.done + 1,
                failed: acc.failed + 1
            }

            maybe_report_progress(scan_id, acc)
        end)
      after
        try do
          ScanPipeline.stop(pipeline)
        catch
          :exit, _ -> :ok
        end
      end

    %{result | walker_skipped: skipped}
  end

  defp maybe_report_progress(scan_id, acc) do
    if acc.done - acc.progress_marker >= @progress_every do
      Catalog.report_progress(scan_id, acc.done, acc.failed)
      %{acc | progress_marker: acc.done}
    else
      acc
    end
  end

  defp failed_bump(%{failed_reason: nil}), do: 0
  defp failed_bump(_ip), do: 1

  defp lost_ip(reason, entry) do
    %ScanPipeline{
      language: entry.language,
      path: entry.path,
      rel_path: entry.rel_path,
      failed_reason: "task exit: #{inspect(reason)}"
    }
  end

  # ------------------------------------------------------------ persistence

  defp finalize(acc, scan, config) do
    ips = Enum.reverse(acc.ips)

    findings =
      for ip <- ips,
          finding <- ip.findings || [],
          do: %{
            language: to_string(ip.language),
            path: ip.rel_path,
            module_name: finding.module_name,
            function_name: finding.function_name,
            line: finding.line,
            end_line: finding.end_line,
            complexity: finding.complexity,
            crap: finding.crap,
            coverage: finding.coverage,
            coverage_source: finding.coverage_source
          }

    manifest =
      for ip <- ips,
          hash = ip.hash || "unknown",
          do: %{path: ip.rel_path, size: ip.size || 0, hash: hash}

    per_language = per_language_stats(ips)
    functions_total = Enum.sum(for {_l, s} <- per_language, do: s["functions"])
    crap_sum = Enum.sum(for {_l, s} <- per_language, do: s["crap_sum"])
    worst = findings |> Enum.map(& &1.crap) |> Enum.max(fn -> 0.0 end)

    stats =
      per_language
      |> Map.merge(coverage_stats(ips))
      |> Map.put("violations", Enum.count(findings, &(&1.crap > config.threshold)))
      |> Map.put("policy", policy_string())
      |> maybe_carry_warning(scan)

    directories = PoopBags.Hotspots.aggregate(ips, config.threshold, config.hotspot_depth)

    commit_started = System.monotonic_time(:millisecond)

    result =
      Catalog.commit_results(scan, findings, manifest, %{
        files_done: length(ips),
        files_failed: Enum.count(ips, & &1.failed_reason),
        files_skipped: Enum.count(ips, & &1.skipped) + (acc.walker_skipped || 0),
        functions_total: functions_total,
        worst_crap: round2(worst),
        avg_crap: round2(crap_sum / max(functions_total, 1)),
        stats: stats,
        directories: directories
      })

    commit_ms = System.monotonic_time(:millisecond) - commit_started

    case result do
      {:ok, _} ->
        # Retention runs strictly after the commit landed: directory
        # aggregates exist before anything can expire, and a sweep failure
        # is logged inside — it can never turn a committed scan into an error.
        PoopBags.Retention.sweep(scan.project_path)

        Catalog.note_stat(scan.id, "timings", %{
          "belt_ms" => acc.belt_ms,
          "commit_ms" => commit_ms
        })

        {:ok, Catalog.get_scan!(scan.id)}

      {:error, reason} ->
        {:error, "could not persist results: #{inspect(reason)}"}
    end
  end

  defp per_language_stats(ips) do
    ips
    |> Enum.reject(& &1.failed_reason)
    |> Enum.group_by(&to_string(&1.language))
    |> Map.new(fn {lang, lang_ips} ->
      functions = Enum.flat_map(lang_ips, &(&1.findings || []))

      {lang,
       %{
         "files" => length(lang_ips),
         "functions" => length(functions),
         "crap_sum" => round2(Enum.sum(Enum.map(functions, & &1.crap)))
       }}
    end)
  end

  defp coverage_stats(ips) do
    findings = Enum.flat_map(ips, &(&1.findings || []))
    measured = Enum.count(findings, &(&1.coverage_source == "measured"))

    %{
      "coverage" => %{
        "measured_functions" => measured,
        "assumed_functions" => length(findings) - measured
      }
    }
  end

  defp policy_string,
    do: "crap=comp^2*(1-cov)^3+comp; complexity=v1 (elixir-ast, zig/kotlin/swift-tokens)"

  # A degraded coverage report is recorded on the row mid-run; the finished
  # summary replaces stats wholesale, so the warning must ride along.
  defp maybe_carry_warning(stats, scan) do
    case Catalog.get_scan!(scan.id).stats do
      %{"coverage_warning" => warning} when is_binary(warning) ->
        Map.put(stats, "coverage_warning", warning)

      _ ->
        stats
    end
  end

  defp round2(value), do: Float.round(value * 1.0, 2)
end
