defmodule PoopBagsWeb.ScanHTML do
  @moduledoc """
  Pages rendered by ScanController.
  """

  use PoopBagsWeb, :html

  embed_templates "scan_html/*"

  def progress_percent(scan) do
    if scan.files_total == 0,
      do: 0,
      else: min(100, round(scan.files_done * 100 / scan.files_total))
  end

  @non_language_stats ~w(policy coverage coverage_warning violations timings)

  def language_stats(scan) do
    scan.stats
    |> Map.drop(@non_language_stats)
    |> Enum.sort_by(fn {_lang, s} -> -(s["crap_sum"] || 0) end)
  end

  def violations_of(%{stats: %{"violations" => v}}), do: "#{v}"
  def violations_of(_), do: "–"

  def violation_rate(%{violations: v, functions: n}) when n > 0,
    do: "#{round(v * 100 / n)}%"

  def violation_rate(_), do: "0%"

  def excess_per_function(%{crap_excess: e, functions: n}) when n > 0,
    do: :erlang.float_to_binary(e / n, decimals: 2)

  def excess_per_function(_), do: "0.0"

  def measured_share(%{measured_functions: m, functions: n}) when n > 0 and m > 0,
    do: "#{round(m * 100 / n)}%"

  def measured_share(_), do: "–"

  def bar_percent(_value, max) when max <= 0, do: 0

  def bar_percent(value, max) when is_number(value) and value > 0,
    do: round(value * 100 / max) |> max(2)

  def bar_percent(_, _), do: 0

  def format_delta(value) when is_float(value) or is_integer(value) do
    cond do
      value > 0 -> "+#{Float.round(value * 1.0, 2)}"
      true -> "#{Float.round(value * 1.0, 2)}"
    end
  end

  def coverage_provenance(scan) do
    case scan.stats["coverage"] do
      %{"measured_functions" => m, "assumed_functions" => a} when m > 0 ->
        "coverage: #{m} measured / #{a} assumed (fallback #{round((scan.assumed_coverage || 0.0) * 100)}%)"

      _ ->
        "coverage assumed #{round((scan.assumed_coverage || 0.0) * 100)}%"
    end
  end

  def config_note(scan) do
    case scan.config do
      %{"source" => source, "digest" => digest} when source != "defaults" ->
        " · config: #{source} (#{String.slice(digest || "", 0, 8)})"

      _ ->
        ""
    end
  end

  def format_when(%{finished_at: %DateTime{} = t}), do: Calendar.strftime(t, "%b %d %H:%M")
  def format_when(%{inserted_at: %DateTime{} = t}), do: Calendar.strftime(t, "%b %d %H:%M")
  def format_when(_), do: "–"

  def coverage_mix(%{
        stats: %{"coverage" => %{"measured_functions" => m, "assumed_functions" => a}}
      })
      when m > 0,
      do: "#{m} meas / #{a} ass"

  def coverage_mix(%{stats: %{"coverage" => %{"assumed_functions" => a}}}), do: "all #{a} ass"
  def coverage_mix(_), do: "–"
end
