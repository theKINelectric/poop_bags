defmodule PoopBags.HotspotsTest do
  use ExUnit.Case, async: true

  alias PoopBags.Hotspots

  defp ip(rel, findings, opts \\ []) do
    %{
      rel_path: rel,
      language: :zig,
      findings: findings,
      failed_reason: Keyword.get(opts, :failed_reason),
      skipped: Keyword.get(opts, :skipped)
    }
  end

  defp f(crap, source \\ "assumed"), do: %{crap: crap, coverage_source: source}

  test "group_of: root files, direct files, nested segments" do
    assert Hotspots.group_of("foo.zig", 1) == "(root)"
    assert Hotspots.group_of("foo.zig", 2) == "(root)"
    assert Hotspots.group_of("src/foo.zig", 1) == "src"
    assert Hotspots.group_of("src/foo.zig", 2) == "src/(direct files)"
    assert Hotspots.group_of("src/workbench/foo.zig", 2) == "src/workbench"
    assert Hotspots.group_of("a/b/c/foo.zig", 3) == "a/b/c"
    assert Hotspots.group_of("a/b/foo.zig", 3) == "a/b/(direct files)"
  end

  test "aggregate: metrics per group at every depth, one row per group" do
    ips = [
      ip("lib/gates.ex", [f(2.0), f(30.0, "measured")]),
      ip("lib/other.ex", [f(21.0)]),
      ip("src/deep/tool.zig", [f(132.0, "measured"), f(5.0)]),
      ip("root.zig", [f(3.0)]),
      ip("skipped/file.ex", [f(100.0)], skipped: true),
      ip("broken.zig", nil, failed_reason: "boom")
    ]

    rows = Hotspots.aggregate(ips, 20.0, 2)
    by_key = Map.new(rows, fn row -> {{row.depth, row.path}, row} end)

    lib = by_key[{1, "lib"}]
    assert lib.files == 2
    assert lib.functions == 3
    # strict: 30.0 and 21.0 violate, 2.0 does not
    assert lib.violations == 2
    # (30-20) + (21-20) + max(2-20, 0)
    assert lib.crap_excess == 11.0
    assert lib.worst_crap == 30.0
    assert lib.measured_functions == 1
    assert lib.assumed_functions == 2

    deep = by_key[{2, "src/deep"}]
    assert deep.files == 1
    assert deep.functions == 2
    assert deep.violations == 1
    assert deep.crap_excess == 112.0
    assert deep.worst_crap == 132.0

    # depth-2 copy of lib is the direct-files bucket, same totals
    assert by_key[{2, "lib/(direct files)"}].functions == 3
    refute Map.has_key?(by_key, {2, "src"})

    # root file alone; broken (failed) and skipped ips never contribute
    root = by_key[{1, "(root)"}]
    assert root.files == 1
    assert root.functions == 1
    refute Map.has_key?(by_key, {1, "skipped"})

    # every depth present
    assert rows |> Enum.map(& &1.depth) |> Enum.uniq() |> Enum.sort() == [1, 2]
  end
end
