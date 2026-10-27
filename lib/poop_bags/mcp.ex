defmodule PoopBags.MCP do
  @moduledoc """
  The MCP face of poop_bags: the same JSON contract as the HTTP API, spoken
  as Model Context Protocol tools over stdio (newline-delimited JSON-RPC).

  Run from a checkout (bin/poop_bags_mcp is the built escript — committed so
  agents don't need to build anything):

      POOP_BAGS_URL=http://localhost:4100 bin/poop_bags_mcp

  Tools:

    * `bag_project`   — scan a directory, wait for the belts, return the
      summary plus the worst findings (the one-call loop).
    * `scan_status`   — poll one scan.
    * `top_findings`  — worst-first findings of a finished scan.
    * `diff_latest`   — outcomes vs the previous scan + the gate verdict.

  The server never builds, runs, or modifies the scanned project; it only
  reads files and hashes them.
  """

  @protocol_version "2024-11-05"
  @default_url "http://localhost:4100"

  @tools [
    %{
      name: "bag_project",
      description:
        "Scan a local project directory for CRAP (Change Risk Anti-Patterns) — " <>
          "complexity x untested pressure, per function, for Elixir/Zig/Kotlin/Swift/Rust/JavaScript/TypeScript. " <>
          "Waits for the scan to finish (up to wait_seconds) and returns the summary " <>
          "plus the worst functions. Static analysis only; the project is never built or run.",
      inputSchema: %{
        type: "object",
        properties: %{
          project_path: %{type: "string", description: "absolute path on this machine"},
          coverage_pct: %{
            type: "number",
            description: "assumed coverage 0-100 (default 0 — the honest default)"
          },
          label: %{type: "string", description: "optional label for the scan row"},
          wait_seconds: %{type: "integer", description: "poll budget (default 300)"}
        },
        required: ["project_path"]
      }
    },
    %{
      name: "scan_status",
      description: "One scan's status: files, functions, worst/avg CRAP, violations, timings.",
      inputSchema: %{
        type: "object",
        properties: %{scan_id: %{type: "integer"}},
        required: ["scan_id"]
      }
    },
    %{
      name: "top_findings",
      description:
        "Worst-first findings of a finished scan (filterable by language). " <>
          "410-style unavailability (retention expiry) is reported as a clear message.",
      inputSchema: %{
        type: "object",
        properties: %{
          scan_id: %{type: "integer"},
          language: %{
            type: "string",
            enum: ["elixir", "zig", "kotlin", "swift", "rust", "javascript", "typescript"]
          },
          limit: %{type: "integer", description: "1-500, default 20"}
        },
        required: ["scan_id"]
      }
    },
    %{
      name: "diff_latest",
      description:
        "Diff a finished scan against its baseline (the previous finished scan of the " <>
          "same project): introduced/regressed/improved/resolved/removed per function, " <>
          "plus gate_passed (false for incomparable scans, new violations, or above-threshold regressions).",
      inputSchema: %{
        type: "object",
        properties: %{scan_id: %{type: "integer"}},
        required: ["scan_id"]
      }
    }
  ]

  def main(_args) do
    Application.ensure_all_started(:inets)

    loop()
  end

  defp loop do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      line ->
        handle_line(line)
        loop()
    end
  end

  defp handle_line(line) do
    case Jason.decode(line) do
      {:ok, %{"id" => id, "method" => method} = request} ->
        # A crashing tool must take down neither the server nor the client's
        # session: answer with a JSON-RPC error and keep the loop alive.
        result =
          try do
            {:ok, dispatch(method, request["params"] || %{})}
          rescue
            e -> {:error, "#{Exception.format(:error, e)}"}
          end

        case result do
          {:ok, :notification} ->
            :ok

          {:ok, payload} ->
            respond(id, payload)

          {:error, message} ->
            respond(id, %{isError: true, content: [%{type: "text", text: message}]})
        end

      {:ok, _notification} ->
        :ok

      _ ->
        :ok
    end
  end

  defp dispatch("initialize", _params) do
    %{
      protocolVersion: @protocol_version,
      capabilities: %{tools: %{}},
      serverInfo: %{name: "poop_bags", version: "0.1.0"}
    }
  end

  defp dispatch("ping", _params), do: %{}

  defp dispatch("tools/list", _params), do: %{tools: @tools}

  defp dispatch("tools/call", %{"name" => name, "arguments" => args}),
    do: call_tool(name, args || %{})

  defp dispatch("notifications/initialized", _params), do: :notification

  defp dispatch(_other, _params), do: %{}

  # ------------------------------------------------------------ tools

  defp call_tool("bag_project", args) do
    case post("/api/scans", %{
           "project_path" => args["project_path"],
           "coverage" => args["coverage_pct"],
           "label" => args["label"]
         }) do
      {:ok, 202, %{"id" => id}} ->
        text(bag_report(id, args["wait_seconds"] || 300))

      {:ok, 422, %{"errors" => errors}} ->
        text("Rejected (422): " <> Jason.encode!(errors))

      {:ok, 429, _} ->
        text("The belts are busy — three scans already running. Retry shortly.")

      {:error, reason} ->
        text("Could not reach poop_bags at #{base_url()}: #{inspect(reason)}")
    end
  end

  defp call_tool("scan_status", %{"scan_id" => id}) do
    text(summary_line(get!("/api/scans/#{id}")))
  end

  defp call_tool("top_findings", %{"scan_id" => id} = args) do
    case fetch_findings(id, args) do
      {:ok, findings} -> text(findings_text(findings))
      {:expired, message} -> text(message)
    end
  end

  defp call_tool("diff_latest", %{"scan_id" => id}) do
    case get("/api/scans/#{id}/diff?against=latest") do
      {:ok, 200, diff} ->
        s = diff["summary"]

        gate = if diff["gate_passed"], do: "PASS ✅", else: "FAIL ⛔"

        rows =
          diff["rows"]
          |> Enum.take(25)
          |> Enum.map_join("\n", fn row ->
            marker = if row["violation"], do: " ⚠️", else: ""

            where =
              if row["module"] != "",
                do: "#{row["module"]}.#{row["function"]}",
                else: row["function"]

            "#{row["outcome"]}#{marker} #{row["language"]} #{where} " <>
              "#{row["path"]}:#{row["current"] && row["current"]["line"]} " <>
              "(#{row["baseline_crap"] || "new"} → #{row["current_crap"] || "gone"})"
          end)

        warnings =
          diff["warnings"] |> Enum.map_join("\n", &"- #{&1}")

        text(
          "gate #{gate} vs baseline ##{diff["baseline_id"]} (threshold #{diff["threshold"]})\n" <>
            "introduced #{s["introduced"]} · regressed #{s["regressed"]} · resolved #{s["resolved"]} · " <>
            "improved #{s["improved"]} · removed #{s["removed"]} · unchanged #{s["unchanged"]}\n" <>
            if(warnings == "", do: "", else: "\nWarnings:\n#{warnings}\n") <> "\n#{rows}"
        )

      {:ok, status, %{"error" => error}} ->
        text("diff unavailable (HTTP #{status}): #{error}")

      {:error, reason} ->
        text("Could not reach poop_bags: #{inspect(reason)}")
    end
  end

  defp call_tool(other, _args),
    do: text("unknown tool #{other} — tools/list has the contract")

  defp bag_report(id, wait_seconds) do
    wait_for_scan(id, wait_seconds)
    summary = get!("/api/scans/#{id}")

    worst =
      case fetch_findings(id, %{"limit" => 10}) do
        {:ok, findings} -> findings_text(findings)
        {:expired, message} -> message
      end

    summary_line(summary) <> "\n\nWorst offenders:\n" <> worst
  end

  # ------------------------------------------------------------ plumbing

  defp base_url, do: System.get_env("POOP_BAGS_URL") || @default_url

  defp get!(path) do
    case get(path) do
      {:ok, _status, body} -> body
      {:error, reason} -> throw({:unreachable, reason})
    end
  end

  defp get(path) do
    request(:get, path, nil)
  end

  defp post(path, body) do
    request(:post, path, Jason.encode!(body))
  end

  defp request(method, path, body) do
    url = base_url() <> path
    content_type = ~c"application/json"

    request =
      case body do
        nil -> {~c"#{url}", []}
        binary -> {~c"#{url}", [{~c"content-type", content_type}], ~c"application/json", binary}
      end

    case :httpc.request(method, request, [], body_format: :binary) do
      {:ok, {{_http, status, _phrase}, _headers, raw}} ->
        case Jason.decode(raw) do
          {:ok, decoded} -> {:ok, status, decoded}
          _ -> {:ok, status, %{}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp wait_for_scan(id, budget, waited \\ 0) when waited <= budget do
    case get("/api/scans/#{id}") do
      {:ok, 200, %{"status" => status}} when status in ["done", "error"] ->
        :ok

      {:ok, 200, _running} ->
        Process.sleep(1000)
        wait_for_scan(id, budget, waited + 1)

      _ ->
        :ok
    end
  end

  defp fetch_findings(id, args) do
    query =
      URI.encode_query(
        Map.new(
          for {k, v} <- %{"language" => args["language"], "limit" => args["limit"] || 20},
              v != nil,
              do: {k, v}
        )
      )

    case get("/api/scans/#{id}/findings?#{query}") do
      {:ok, 200, %{"findings" => findings}} -> {:ok, findings}
      {:ok, 410, %{"error" => error}} -> {:expired, error}
      {:ok, status, %{"error" => error}} -> {:expired, "HTTP #{status}: #{error}"}
      {:error, reason} -> {:expired, "unreachable: #{inspect(reason)}"}
    end
  end

  defp summary_line(scan) do
    files = scan["files"] || %{}

    "scan ##{scan["id"]} [#{scan["status"]}] #{scan["label"] || scan["project_path"]}\n" <>
      "files #{files["done"] || 0}/#{files["total"] || 0} · failed #{files["failed"] || 0} · " <>
      "functions #{scan["functions_total"] || 0} · violations #{scan["violations"]}\n" <>
      "worst CRAP #{scan["worst_crap"]} · avg #{scan["avg_crap"]} · " <>
      "threshold #{scan["threshold"]}"
  end

  defp findings_text(findings) do
    findings
    |> Enum.map_join("\n", fn f ->
      where = if f["module"] != "", do: "#{f["module"]}.", else: ""

      "CRAP #{f["crap"]} · cx #{f["complexity"]} · #{f["language"]} #{where}#{f["function"]} #{f["path"]}:#{f["line"]}"
    end)
  end

  defp text(content), do: %{content: [%{type: "text", text: content}]}

  defp respond(id, result) do
    IO.puts(Jason.encode!(%{jsonrpc: "2.0", id: id, result: result}))
  end
end
