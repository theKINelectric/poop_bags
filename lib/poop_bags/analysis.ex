defmodule PoopBags.Analysis do
  @moduledoc """
  Language dispatch: source text in, per-function complexity findings out.

  Elixir gets the real AST; Zig/Kotlin/Swift get the token analyzer (see
  `PoopBags.TokenAnalyzer` for the method and its limits).
  """

  alias PoopBags.Analysis.Finding
  alias PoopBags.ElixirAnalyzer
  alias PoopBags.TokenAnalyzer

  @spec analyze(binary(), :elixir | :zig | :kotlin | :swift | :rust) ::
          {:ok, [Finding.t()]} | {:error, :parse}
  def analyze(source, :elixir), do: ElixirAnalyzer.analyze(source)

  def analyze(source, lang) when lang in [:zig, :kotlin, :swift, :rust],
    do: {:ok, TokenAnalyzer.analyze(source, lang)}
end
