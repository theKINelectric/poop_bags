defmodule PoopBags.JavaScriptAnalyzer do
  @moduledoc """
  JS-family AST analysis through the trusted shared parser. No subject module,
  configuration, compiler or build is loaded. Physical lines shared at function
  boundaries are ambiguous for line-only LCOV and are not attributed as measured.
  """
  alias PoopBags.Analysis.Finding

  def analyze(source, language, opts \\ []) do
    with {:ok, findings, _meta} <- analyze_with_meta(source, language, opts),
         do: {:ok, findings}
  end

  def analyze_with_meta(source, language, opts \\ []) do
    with {:ok, result} <- parse(source, language, opts) do
      functions = result["functions"]
      ambiguous = ambiguous_lines(functions)

      metadata =
        result["meta"]
        |> Map.take(["parser", "parser_version", "package_version"])
        |> Map.put("policy", result["policy"])
        |> Map.put("skipped", result["skipped"])

      findings =
        Enum.map(functions, fn f ->
          %Finding{
            module_name: f["module"] || "",
            function_name: f["name"],
            line: f["line_start"],
            end_line: f["line_end"],
            complexity: f["complexity"],
            ambiguous_coverage_lines: ambiguous
          }
        end)

      {:ok, findings, metadata}
    end
  end

  def explain(source, language, name, opts \\ []) do
    with {:ok, result} <- parse(source, language, opts),
         f when not is_nil(f) <- Enum.find(result["functions"], &(&1["name"] == name)) do
      contributions =
        f["branches"]
        |> Enum.frequencies_by(& &1["kind"])
        |> Enum.sort_by(fn {kind, n} -> {-n, kind} end)

      %{line: f["line_start"], contributions: contributions}
    else
      _ -> :error
    end
  end

  defp parse(source, language, opts) do
    filename =
      Keyword.get(opts, :path, if(language == :typescript, do: "source.ts", else: "source.js"))

    JsTsParser.parse(source, filename, opts)
  end

  defp ambiguous_lines(functions) do
    boundaries = functions |> Enum.flat_map(&[&1["line_start"], &1["line_end"]]) |> MapSet.new()

    events =
      Enum.reduce(functions, %{}, fn f, acc ->
        acc
        |> Map.update(f["line_start"], 1, &(&1 + 1))
        |> Map.update(f["line_end"] + 1, -1, &(&1 - 1))
      end)

    positions = (Map.keys(events) ++ MapSet.to_list(boundaries)) |> Enum.uniq() |> Enum.sort()

    {_count, ambiguous} =
      Enum.reduce(positions, {0, MapSet.new()}, fn line, {count, acc} ->
        current = count + Map.get(events, line, 0)

        acc =
          if current > 1 and MapSet.member?(boundaries, line),
            do: MapSet.put(acc, line),
            else: acc

        {current, acc}
      end)

    ambiguous
  end
end
