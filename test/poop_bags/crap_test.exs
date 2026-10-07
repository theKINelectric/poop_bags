defmodule PoopBags.CrapTest do
  use ExUnit.Case, async: true

  alias PoopBags.Crap

  test "zero coverage: CRAP = comp² + comp" do
    assert Crap.score(1, 0.0) == 2.0
    assert Crap.score(2, 0.0) == 6.0
    assert Crap.score(10, 0.0) == 110.0
  end

  test "full coverage collapses CRAP to the complexity itself" do
    assert Crap.score(20, 1.0) == 20.0
  end

  test "coverage shrinks but never reorders (monotone in complexity)" do
    scores = for c <- 1..30, do: Crap.score(c, 0.4)
    assert scores == Enum.sort(scores)
  end

  test "coverage is clamped to [0.0, 1.0]" do
    assert Crap.score(5, 7.0) == Crap.score(5, 1.0)
    assert Crap.score(5, -1.0) == Crap.score(5, 0.0)
  end

  test "bands" do
    assert Crap.band(2.0) == :fresh
    assert Crap.band(5.0) == :fresh
    assert Crap.band(6.0) == :whiffy
    assert Crap.band(20.0) == :whiffy
    assert Crap.band(21.0) == :foul
    assert Crap.band(50.0) == :foul
    assert Crap.band(50.01) == :biohazard
  end
end
