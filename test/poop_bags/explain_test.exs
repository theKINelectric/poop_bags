defmodule PoopBags.ExplainTest do
  use ExUnit.Case, async: true

  alias PoopBags.ElixirAnalyzer
  alias PoopBags.TokenAnalyzer

  test "token analyzer breaks a zig function into token kinds" do
    src = """
    fn transform(input: []const u8) Error!u32 {
        if (input.len > 10) return error.TooLarge;
        var i: usize = 0;
        while (i < input.len) : (i += 1) {
            if (input[i] == '\\r' and i + 1 < input.len) i += 1;
        }
        const x = null orelse return error.Nil;
        return 0;
    }
    """

    assert %{contributions: contributions} = TokenAnalyzer.explain(src, :zig, "transform")

    kinds = Map.new(contributions)
    assert kinds["if"] == 2
    assert kinds["while"] == 1
    assert kinds["and"] == 1
    assert kinds["orelse"] == 1
    # sum + 1 base = complexity 6
    assert 1 + Enum.sum(Enum.map(contributions, &elem(&1, 1))) == 6
  end

  test "token analyzer explain returns :error for an unknown function" do
    assert :error = TokenAnalyzer.explain("fn a() void {}", :zig, "nope")
  end

  test "token analyzer explain: kotlin when arms and elvis" do
    src = """
    fun pick(x: Int): Int {
        val n = x ?: 0
        return when (x) {
            1 -> 10
            2 -> 20
            else -> 0
        }
    }
    """

    assert %{contributions: contributions} = TokenAnalyzer.explain(src, :kotlin, "pick")
    kinds = Map.new(contributions)
    assert kinds["->"] == 3
    assert kinds["elvis ?:"] == 1
  end

  test "elixir analyzer breaks a function into constructs" do
    src = """
    defmodule T do
      def f(x) when x > 0 and x < 9 do
        y =
          case x do
            1 -> if x, do: 1, else: 2
            _ -> 3
          end

        y || f(x - 1)
      end
    end
    """

    contributions = ElixirAnalyzer.explain(src, "f/1")
    kinds = Map.new(contributions)

    assert kinds["case arm"] == 2
    assert kinds["if"] == 1
    assert kinds["boolean op"] == 2
    # case arms 2 + if 1 + and (guard) 1 + || 1 = 5 → complexity 6
    assert 1 + Enum.sum(Enum.map(contributions, &elem(&1, 1))) == 6
  end

  test "elixir analyzer explain sums across clauses" do
    src = """
    defmodule T do
      def g(1), do: if true, do: 1, else: 2
      def g(2), do: 3
    end
    """

    contributions = ElixirAnalyzer.explain(src, "g/1")
    kinds = Map.new(contributions)
    assert kinds["if"] == 1
  end

  test "elixir analyzer explain returns :error for unknown" do
    assert :error = ElixirAnalyzer.explain("defmodule T do\nend", "nope/0")
  end
end
