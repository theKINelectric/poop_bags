defmodule PoopBags.Analysis do
  @moduledoc "Language dispatch, preserving each analyzer's policy and failure evidence."
  alias PoopBags.{ElixirAnalyzer, TokenAnalyzer, JavaScriptAnalyzer}

  def analyze(source, language, opts \\ [])
  def analyze(source, :elixir, _opts), do: ElixirAnalyzer.analyze(source)

  def analyze(source, language, opts) when language in [:javascript, :typescript],
    do: JavaScriptAnalyzer.analyze(source, language, opts)

  def analyze(source, language, _opts) when language in [:zig, :kotlin, :swift, :rust],
    do: {:ok, TokenAnalyzer.analyze(source, language)}

  def analyze_with_meta(source, language, opts \\ [])

  def analyze_with_meta(source, language, opts) when language in [:javascript, :typescript],
    do: JavaScriptAnalyzer.analyze_with_meta(source, language, opts)

  def analyze_with_meta(source, language, opts) do
    with {:ok, findings} <- analyze(source, language, opts), do: {:ok, findings, nil}
  end
end
