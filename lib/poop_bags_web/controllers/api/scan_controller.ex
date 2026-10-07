defmodule PoopBagsWeb.API.ScanController do
  @moduledoc """
  JSON face of the service, for scripting the bagging.

      curl -X POST http://localhost:4000/api/scans \
        -H 'content-type: application/json' \
        -d '{"project_path": "/abs/path", "coverage": 0}'

      curl http://localhost:4000/api/scans/1
      curl 'http://localhost:4000/api/scans/1/findings?language=zig&limit=20'
  """

  use PoopBagsWeb, :controller

  alias PoopBags.Catalog
  alias PoopBags.ScanSupervisor

  @doc """
  The machine-readable front door: everything an agent needs to drive the
  service over HTTP — endpoints, the poll loop, semantics, and MCP wiring.
  """
  def discover(conn, _params) do
    base = self_base(conn)

    json(conn, %{
      service: "poop_bags",
      description:
        "Bags the CRAP (Change Risk Anti-Patterns) of a local project directory — " <>
          "static analysis of Elixir, Zig, Kotlin, and Swift. Never builds, runs, or modifies the scanned project.",
      developed_by: "iStellar~iModal 🛸🕳️",
      formula: "CRAP(m) = complexity(m)^2 × (1 − coverage(m))^3 + complexity(m)",
      bands: %{"fresh" => "≤ 5", "whiffy" => "≤ 20", "foul" => "≤ 50", "biohazard" => "> 50"},
      quickstart: [
        "curl -s #{base}/api/scans -H 'content-type: application/json' " <>
          "-d '{\"project_path\": \"/abs/path/to/project\", \"coverage\": 0}'",
        "poll: curl -s #{base}/api/scans/$ID until status is done or error",
        "curl -s '#{base}/api/scans/$ID/findings?limit=20' — worst-first findings",
        "curl -s '#{base}/api/scans/$ID/diff?against=latest' — outcomes + gate_passed"
      ],
      endpoints: %{
        "POST /api/scans" => %{
          body: %{
            project_path: "absolute path (required)",
            coverage: "assumed % 0-100 (default 0)",
            label: "optional"
          },
          returns: %{id: "scan id", status: "running", show_url: "human page"},
          notes:
            "202 accepted; 422 if the path is not an existing directory; 429 if 3 scans already run"
        },
        "GET /api/scans/:id" => %{
          returns:
            "status, files, functions_total, worst_crap, avg_crap, violations, coverage mix, timings, pinned, details_expired_at"
        },
        "GET /api/scans/:id/findings" => %{
          query: %{language: "elixir|zig|kotlin|swift", limit: "1-500 (default 100)"},
          returns: "worst-first rows: function, module, path, line, complexity, crap",
          notes: "410 Gone when detail retention expired the scan"
        },
        "GET /api/scans/:id/diff" => %{
          query: %{against: "latest|<scan id>", limit: "row cap"},
          returns:
            "per-function outcomes (introduced/regressed/improved/resolved/removed/unchanged), gate_passed, comparability warnings",
          notes: "410 Gone when either side's details expired or never finished"
        }
      },
      semantics: %{
        violation:
          "CRAP strictly above the scan's threshold (default 20; .poopbags.json or the web form can set it)",
        gate:
          "gate_passed=false iff introduced violations or above-threshold regressions vs the baseline",
        identity: "language + path + module + function — line numbers never matter",
        coverage:
          "assumed (default 0%) unless the project names an LCOV/ExCoveralls report in .poopbags.json",
        retention:
          "the latest 3 done scans per project keep details; older ones keep summaries and directory aggregates (410 on detail endpoints)"
      },
      mcp: %{
        description:
          "This same contract as MCP tools over stdio (bag_project, scan_status, top_findings, diff_latest)",
        server: "bin/poop_bags_mcp in the repo (escript; runs anywhere with Erlang/Elixir)",
        env: "POOP_BAGS_URL (default http://localhost:4100)"
      }
    })
  end

  def create(conn, params) do
    attrs = %{
      "project_path" => params["project_path"],
      "label" => params["label"],
      "assumed_coverage" => coverage_ratio(params["coverage"])
    }

    case Catalog.create_scan(attrs) do
      {:ok, scan} ->
        case ScanSupervisor.start_scan(scan.id) do
          :ok ->
            conn
            |> put_status(:accepted)
            |> json(%{
              id: scan.id,
              status: "running",
              show_url: self_base(conn) <> "/scans/#{scan.id}"
            })

          {:error, :busy} ->
            Catalog.fail_scan(scan, "scan belts are busy")
            conn |> put_status(:too_many_requests) |> json(%{error: "too many scans running"})

          {:error, reason} ->
            Catalog.fail_scan(scan, inspect(reason))
            conn |> put_status(:internal_server_error) |> json(%{error: "could not start scan"})
        end

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  def show(conn, %{"id" => id}) do
    scan = Catalog.get_scan!(id)

    json(conn, %{
      id: scan.id,
      status: scan.status,
      project_path: scan.project_path,
      label: scan.label,
      assumed_coverage: scan.assumed_coverage,
      files: %{
        total: scan.files_total,
        done: scan.files_done,
        failed: scan.files_failed,
        skipped: scan.files_skipped
      },
      functions_total: scan.functions_total,
      worst_crap: scan.worst_crap,
      avg_crap: scan.avg_crap,
      violations: scan.stats["violations"],
      by_language:
        Map.drop(scan.stats, ["policy", "coverage", "coverage_warning", "violations", "timings"]),
      policy: scan.stats["policy"],
      threshold: scan.threshold,
      coverage: scan.stats["coverage"],
      coverage_warning: scan.stats["coverage_warning"],
      timings: scan.stats["timings"],
      config: scan.config,
      pinned: scan.pinned,
      details_expired_at: scan.details_expired_at,
      error: scan.error,
      started_at: scan.started_at,
      finished_at: scan.finished_at,
      findings_url: self_base(conn) <> "/api/scans/#{scan.id}/findings"
    })
  end

  def diff(conn, %{"id" => id} = params) do
    scan = Catalog.get_scan!(id)

    if not Catalog.Scan.details_available?(scan) do
      conn
      |> put_status(:gone)
      |> json(%{error: "scan #{scan.id} details expired by retention or not yet finished"})
    else
      respond_diff(conn, scan, PoopBagsWeb.Baseline.resolve(params, scan), params)
    end
  end

  defp respond_diff(conn, _scan, :none, _params) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "no baseline scan of this project yet"})
  end

  defp respond_diff(conn, _scan, {:unavailable, baseline}, _params) do
    reason =
      if baseline.status != "done",
        do: "has not finished (#{baseline.status}) and carries no findings",
        else: "details expired by retention"

    conn
    |> put_status(:gone)
    |> json(%{
      error:
        "baseline scan #{baseline.id} #{reason} " <>
          "(keep #{PoopBags.Retention.keep_count()}; pin a scan to protect it)"
    })
  end

  defp respond_diff(conn, scan, {:ok, baseline}, params) do
    diff = PoopBags.Diff.between(baseline, scan, limit: parse_limit(params["limit"]))

    json(conn, %{
      scan_id: scan.id,
      baseline_id: baseline.id,
      threshold: diff.threshold,
      comparable: diff.comparable,
      warnings: diff.warnings,
      summary: diff.summary,
      gate_passed: PoopBags.Diff.gate_passed?(diff),
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

  def findings(conn, %{"id" => id} = params) do
    scan = Catalog.get_scan!(id)

    if Catalog.Scan.details_available?(scan) do
      limit = parse_limit(params["limit"])

      findings =
        Enum.map(Catalog.top_findings(scan, language: params["language"], limit: limit), fn f ->
          %{
            language: f.language,
            path: f.path,
            module: f.module_name,
            function: f.function_name,
            line: f.line,
            complexity: f.complexity,
            crap: f.crap
          }
        end)

      json(conn, %{scan_id: scan.id, count: length(findings), findings: findings})
    else
      conn
      |> put_status(:gone)
      |> json(%{
        error:
          "scan #{scan.id} details expired by retention — summaries and directory aggregates remain"
      })
    end
  end

  # This service's own origin as the *caller* sees it — request scheme/host
  # plus the configured URL path prefix — so generated links work identically
  # from loopback, the house-name plane, and the phi path plane.
  defp self_base(conn) do
    port =
      case conn.port do
        p when p in [80, 443] -> ""
        p -> ":#{p}"
      end

    "#{conn.scheme}://#{conn.host}#{port}#{Application.get_env(:poop_bags, :url_path, "")}"
  end

  defp coverage_ratio(nil), do: 0.0

  defp coverage_ratio(raw) when is_binary(raw), do: coverage_ratio(Float.parse(raw))
  defp coverage_ratio({pct, _}), do: coverage_ratio(pct)

  defp coverage_ratio(pct) when is_number(pct),
    do: pct |> max(0.0) |> min(100.0) |> then(&Float.round(&1 / 100.0, 4))

  defp parse_limit(nil), do: 100

  defp parse_limit(raw) do
    case Integer.parse(to_string(raw)) do
      {n, _} -> n |> max(1) |> min(500)
      :error -> 100
    end
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
