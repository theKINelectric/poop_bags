defmodule PoopBags.Glob do
  @moduledoc """
  A tiny path glob matcher for exclusion patterns: `*` (within a segment),
  `?` (one char), `**` (any number of segments). Patterns match the whole
  project-relative path, `/`-separated.

      match?("experiments/**", "experiments/hb1/a.zig")   #=> true
      match?("**/*.gen.zig", "src/gen/x.gen.zig")        #=> true
      match?("apps/*", "apps/amrita/src/x.zig")          #=> false
  """

  @doc "Compiles and matches in one step."
  @spec match?(String.t(), String.t()) :: boolean()
  def match?(pattern, path) when is_binary(pattern) and is_binary(path) do
    pattern
    |> compile()
    |> Regex.match?(path)
  end

  @doc "Pre-compile a pattern once when matching many paths."
  @spec compile(String.t()) :: Regex.t()
  def compile(pattern) do
    source = join(String.split(pattern, "/", trim: false))
    Regex.compile!("\\A" <> source <> "\\Z")
  end

  # `**/` may also match zero segments, so `**/*.gen.zig` hits both
  # `src/x.gen.zig` and a bare `x.gen.zig`.
  defp join(["**" | rest]) when rest != [] do
    "(?:.*/)?" <> join(rest)
  end

  defp join([seg]), do: segment(seg)

  defp join([seg | rest]), do: segment(seg) <> "/" <> join(rest)

  defp segment("**"), do: ".*"

  defp segment(seg) do
    seg
    |> String.graphemes()
    |> Enum.map(fn
      "*" -> "[^/]*"
      "?" -> "[^/]"
      c -> Regex.escape(c)
    end)
    |> Enum.join()
  end
end
