defmodule PoopBagsWeb.Baseline do
  @moduledoc """
  Resolves the `?against=` parameter into a usable baseline, shared by the
  web and API diff actions.

  `latest` (or blank) picks the newest done scan of the same project; an
  integer names a scan explicitly (garbage behaves like "no baseline", not a
  crash). A resolved baseline that never finished or had its details expired
  by retention comes back as `{:unavailable, scan}` so callers can answer
  "unavailable" instead of diffing against an empty side.
  """

  alias PoopBags.Catalog

  @spec resolve(map(), Catalog.Scan.t()) ::
          {:ok, Catalog.Scan.t()} | :none | {:unavailable, Catalog.Scan.t()}
  def resolve(params, scan) do
    case params["against"] do
      nil ->
        from_latest(scan)

      "" ->
        from_latest(scan)

      "latest" ->
        from_latest(scan)

      raw when is_binary(raw) ->
        case Integer.parse(raw) do
          {int_id, ""} -> Catalog.get_scan(int_id) |> check()
          _ -> :none
        end
    end
  end

  defp from_latest(scan) do
    case Catalog.latest_baseline(scan) do
      nil -> :none
      baseline -> check(baseline)
    end
  end

  defp check(nil), do: :none

  defp check(baseline) do
    if Catalog.Scan.details_available?(baseline),
      do: {:ok, baseline},
      else: {:unavailable, baseline}
  end
end
