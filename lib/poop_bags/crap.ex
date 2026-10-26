defmodule PoopBags.Crap do
  @moduledoc """
  The Change Risk Anti-Patterns score, after Bob Martin / PHPUnit:

      CRAP(m) = complexity(m)² × (1 − coverage(m))³ + complexity(m)

  High complexity with no tests to pin behavior down is change risk. A
  well-tested function shrinks its CRAP even when complex. This service has
  no per-function coverage data, so a scan assumes one coverage figure for
  everything (0% by default — the honest, conservative choice).

  Stench bands for the UI:

      fresh      CRAP ≤ 5     — nothing rotting here
      whiffy     CRAP ≤ 20    — hold your nose, consider a refactor
      foul       CRAP ≤ 50    — the bag is straining
      biohazard  CRAP > 50    — evacuate the area
  """

  @type band :: :fresh | :whiffy | :foul | :biohazard

  @doc "CRAP score for a cyclomatic complexity and a coverage ratio (0.0–1.0)."
  @spec score(pos_integer(), float()) :: float()
  def score(complexity, coverage) when is_integer(complexity) and complexity >= 1 do
    coverage = clamp_coverage(coverage)
    round2(complexity * complexity * :math.pow(1.0 - coverage, 3) + complexity)
  end

  @spec band(number()) :: band()
  def band(crap) when crap <= 5.0, do: :fresh
  def band(crap) when crap <= 20.0, do: :whiffy
  def band(crap) when crap <= 50.0, do: :foul
  def band(_crap), do: :biohazard

  @spec band_label(band()) :: String.t()
  def band_label(:fresh), do: "fresh"
  def band_label(:whiffy), do: "whiffy"
  def band_label(:foul), do: "foul"
  def band_label(:biohazard), do: "biohazard"

  defp clamp_coverage(cov) when is_float(cov), do: cov |> max(0.0) |> min(1.0)
  defp clamp_coverage(cov) when is_integer(cov), do: clamp_coverage(cov * 1.0)
  defp clamp_coverage(_), do: 0.0

  defp round2(value), do: Float.round(value * 1.0, 2)
end
