defmodule PoopBags.Coverage do
  @moduledoc """
  Real coverage, ingested from a report instead of assumed.

  Supported formats (both produced by the usual toolchains, parsed here —
  never executed):

  * **LCOV** (`SF:`/`DA:<line>,<count>` records) — gcov, llvm-cov, kcov and
    many more can emit it.
  * **ExCoveralls JSON** (`mix coveralls.json`) — line-indexed hit arrays
    for Elixir.

  Mapping: report lines are attributed to the *innermost* function whose
  `[line, end_line]` span contains them (the same ownership rule the token
  analyzer uses), and a function's measured coverage is
  covered-executable-lines ÷ executable-lines-owned-by-it. A function the
  report says nothing about is **unknown** — never measured-zero — and falls
  back to the scan's assumed coverage with the provenance recorded.
  """

  alias PoopBags.Analysis.Finding

  @type line_map :: %{required(pos_integer()) => non_neg_integer()}
  @type t :: %{required(String.t()) => line_map()}

  # ---------------------------------------------------------------- parsing

  @doc "Parses a coverage report file (format detected from content)."
  @spec parse_file(Path.t()) :: {:ok, t(), String.t()} | {:error, String.t()}
  def parse_file(path) do
    case File.read(path) do
      {:ok, content} -> parse(content, path)
      {:error, reason} -> {:error, "could not read coverage report #{path}: #{inspect(reason)}"}
    end
  end

  @doc "Parses report content; returns a map keyed by project-relative path."
  @spec parse(binary(), Path.t()) :: {:ok, t(), String.t()} | {:error, String.t()}
  def parse(content, path) do
    cond do
      String.starts_with?(String.trim_leading(content), "{") ->
        parse_ex_coveralls(content, path)

      content =~ "SF:" and content =~ "DA:" ->
        parse_lcov(content)

      true ->
        {:error, "#{path}: unrecognized coverage format (expected LCOV or ExCoveralls JSON)"}
    end
  end

  # LCOV: SF:<file> opens a record; DA:<line>,<count>[,...] per executable
  # line; end_of_record closes it. Duplicate records for a file merge with
  # counts summed (some tools emit one file per test).
  defp parse_lcov(content) do
    files =
      content
      |> String.split(["\r\n", "\n"])
      |> Enum.reduce(%{current: nil, files: %{}}, fn line, acc ->
        cond do
          record = strip_prefix(line, "SF:") ->
            %{acc | current: normalize_path(record)}

          da = strip_prefix(line, "DA:") ->
            add_da(acc, da)

          String.starts_with?(line, "end_of_record") ->
            %{acc | current: nil}

          true ->
            acc
        end
      end)
      |> Map.fetch!(:files)

    {:ok, files, "lcov"}
  end

  defp add_da(%{current: nil} = acc, _da), do: acc

  defp add_da(%{current: file, files: files} = acc, da) do
    with [line_s, count_s | _rest] <- String.split(da, ","),
         {line, ""} <- Integer.parse(line_s),
         {count, ""} <- Integer.parse(count_s) do
      updated =
        Map.update(files, file, %{line => count}, fn line_map ->
          Map.update(line_map, line, count, &(&1 + count))
        end)

      %{acc | files: updated}
    else
      _ -> acc
    end
  end

  defp strip_prefix(line, prefix) do
    if String.starts_with?(line, prefix) do
      line |> binary_part(byte_size(prefix), byte_size(line) - byte_size(prefix)) |> String.trim()
    end
  end

  defp parse_ex_coveralls(content, path) do
    case Jason.decode(content) do
      {:ok, %{"coverage" => report}} ->
        entries =
          report
          |> coverage_files()
          |> Enum.map(fn %{"name" => name, "coverage" => counts} ->
            {normalize_path(name), line_map_from_counts(counts)}
          end)
          |> Map.new()

        {:ok, entries, "ex_coveralls"}

      {:ok, _} ->
        {:error, "#{path}: ExCoveralls JSON without a \"coverage\" object"}

      {:error, %Jason.DecodeError{} = e} ->
        {:error, "#{path}: invalid JSON: #{Exception.message(e)}"}
    end
  end

  defp coverage_files(%{"files" => files}) when is_list(files), do: files
  defp coverage_files(files) when is_list(files), do: files
  defp coverage_files(_), do: []

  defp line_map_from_counts(counts) do
    counts
    |> Enum.with_index(1)
    |> Enum.reject(fn {count, _line} -> is_nil(count) end)
    |> Map.new(fn {count, line} -> {line, count} end)
  end

  @doc """
  Aligns report paths with the project's actual file list.

  Reports built elsewhere (CI) carry absolute paths that will never equal a
  project-relative scan path. For every report path not already among
  `known_paths`, if exactly one known path is its suffix, the data moves to
  that key. Ambiguous suffixes keep the original key.
  """
  @spec align(t(), [String.t()]) :: t()
  def align(lines, known_paths) do
    known = MapSet.new(known_paths)

    Enum.reduce(lines, %{}, fn {path, data}, acc ->
      cond do
        MapSet.member?(known, path) ->
          Map.put(acc, path, data)

        true ->
          case suffix_matches(path, known) do
            [one] ->
              merged = Map.merge(Map.get(acc, one, %{}), data, fn _l, a, b -> a + b end)
              Map.put(acc, one, merged)

            _ ->
              Map.put(acc, path, data)
          end
      end
    end)
  end

  defp suffix_matches(path, known) do
    Enum.filter(known, fn kp -> String.ends_with?(path, "/" <> kp) end)
  end

  # ---------------------------------------------------------------- mapping

  @doc """
  Attaches measured coverage to one file's findings.

  A line belongs to the innermost function span containing it, so outer
  functions don't credit nested ones. Functions the report says nothing
  about come back with source `"unknown"` and no coverage — the caller
  applies the assumed fallback.
  """
  @spec attach([Finding.t()], line_map()) :: [Finding.t()]
  def attach(findings, lines) when lines == %{}, do: mark_unknown(findings)

  def attach(findings, lines) do
    spans =
      findings
      |> Enum.map(&{&1.line, max(&1.end_line, &1.line)})
      |> Enum.sort()

    findings
    |> Enum.map(fn finding ->
      span = {finding.line, max(finding.end_line, finding.line)}

      eligible_lines = Map.drop(lines, MapSet.to_list(finding.ambiguous_coverage_lines))

      case measure(span, eligible_lines, spans) do
        {:ok, ratio} -> %{finding | coverage: ratio, coverage_source: "measured"}
        :unknown -> %{finding | coverage_source: "unknown"}
      end
    end)
  end

  defp mark_unknown(findings) do
    Enum.map(findings, &%{&1 | coverage_source: "unknown"})
  end

  defp measure({start_line, end_line}, lines, all_spans) do
    owned =
      Enum.filter(lines, fn {line, _hits} ->
        line >= start_line and line <= end_line and
          owned_by?(all_spans, line, start_line, end_line)
      end)

    case owned do
      [] -> :unknown
      owned -> {:ok, ratio(owned)}
    end
  end

  defp owned_by?(all_spans, line, start_line, end_line) do
    containing = Enum.filter(all_spans, fn {s, e} -> line >= s and line <= e end)

    containing != [] and
      Enum.min_by(containing, fn {s, e} -> e - s end) == {start_line, end_line}
  end

  defp ratio(owned) do
    covered = Enum.count(owned, fn {_line, hits} -> hits > 0 end)
    Float.round(covered / length(owned), 4)
  end

  # ---------------------------------------------------------------- helpers

  defp normalize_path(path) do
    path
    |> String.trim_leading()
    |> String.trim_leading("./")
    |> String.trim_leading("/")
    |> Path.split()
    |> Enum.drop_while(&(&1 == "."))
    |> Enum.join("/")
  end
end
