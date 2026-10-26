defmodule PoopBags.Hotspots do
  @moduledoc """
  Directory hotspot aggregation: where the CRAP pools in a project.

  Computed from one scan's in-memory belt output and persisted as durable
  per-directory rows (`scan_directories`) inside the scan's commit
  transaction — so the aggregates exist before retention can expire the
  per-function details, and directory trends survive detail expiry.

  Every bagged file lands in exactly one group per display depth:

      depth 1:  "(root)" · "src"
      depth 2:  "(root)" · "src/(direct files)" · "src/workbench"

  A file directly under a segment that also has subdirectories gets its own
  `"<segment>/(direct files)"` bucket, and repository-root files sit in
  `"(root)"`.

  Metrics per group (threshold = the scan's effective violation threshold,
  strict comparison, same rule as the diff/CI gate):

    * `violations`  — functions with CRAP > threshold
    * `crap_excess` — Σ max(CRAP − threshold, 0): the above-threshold
      burden and the default sort. It deliberately grows with directory
      size; pair it with the violation rate when comparing differently
      sized directories.
    * `worst_crap`  — the single worst function
    * `measured_functions` / `assumed_functions` — coverage provenance mix,
      since a coverage import going missing raises CRAP without any code
      changing.
  """

  @type row :: %{
          required(:path) => String.t(),
          required(:depth) => pos_integer(),
          required(:files) => non_neg_integer(),
          required(:functions) => non_neg_integer(),
          required(:violations) => non_neg_integer(),
          required(:worst_crap) => float(),
          required(:crap_excess) => float(),
          required(:measured_functions) => non_neg_integer(),
          required(:assumed_functions) => non_neg_integer()
        }

  @doc """
  Aggregates non-failed, non-skipped belt IPs into one row per
  (depth, directory group), for depths `1..max_depth`.
  """
  @spec aggregate([map()], number(), pos_integer()) :: [row()]
  def aggregate(ips, threshold, max_depth \\ 2) do
    ips = Enum.reject(ips, &(&1.failed_reason || &1.skipped))

    grouped =
      for depth <- 1..max_depth do
        ips
        |> Enum.group_by(&group_of(&1.rel_path, depth))
        |> Enum.sort_by(fn {path, _} -> path end)
        |> Enum.map(fn {path, group_ips} ->
          aggregate_group(path, depth, group_ips, threshold)
        end)
      end

    List.flatten(grouped)
  end

  @doc "The display-level group a project-relative path belongs to at `depth`."
  @spec group_of(String.t(), pos_integer()) :: String.t()
  def group_of(rel_path, depth) do
    segments_of(String.split(rel_path, "/"), depth)
  end

  defp segments_of([_file], _depth), do: "(root)"
  # A file sitting directly in a segment that also has subdirectories gets
  # its own bucket, so groups at one depth never overlap.
  defp segments_of(segs, depth) when length(segs) <= depth do
    segs |> Enum.take(depth - 1) |> Enum.join("/") |> then(&"#{&1}/(direct files)")
  end

  defp segments_of(segs, depth), do: segs |> Enum.take(depth) |> Enum.join("/")

  defp aggregate_group(path, depth, ips, threshold) do
    findings = Enum.flat_map(ips, &(&1.findings || []))

    %{
      path: path,
      depth: depth,
      files: length(ips),
      functions: length(findings),
      violations: Enum.count(findings, &(&1.crap > threshold)),
      worst_crap: findings |> Enum.map(& &1.crap) |> Enum.max(fn -> 0.0 end) |> round2(),
      crap_excess: findings |> Enum.map(&max(&1.crap - threshold, 0.0)) |> Enum.sum() |> round2(),
      measured_functions: Enum.count(findings, &(&1.coverage_source == "measured")),
      assumed_functions: Enum.count(findings, &(&1.coverage_source != "measured"))
    }
  end

  defp round2(value), do: Float.round(value * 1.0, 2)
end
