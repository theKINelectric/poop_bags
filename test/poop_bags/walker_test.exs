defmodule PoopBags.WalkerTest do
  use ExUnit.Case, async: true

  alias PoopBags.Walker

  @tag :tmp_dir
  test "collects known languages, skips junk dirs and other extensions", ctx do
    root = ctx.tmp_dir

    write(root, "lib/one.ex", "defmodule One do\nend\n")
    write(root, "src/two.zig", "fn two() void {}\n")
    write(root, "app/three.kt", "fun three() = 1\n")
    write(root, "ios/four.swift", "func four() {}\n")
    write(root, "scripts/five.exs", "IO.puts(:hi)\n")
    write(root, "notes/readme.md", "nope")
    write(root, "node_modules/pkg/six.js", "junk")
    write(root, ".git/HEAD", "junk")
    write(root, ".zig-cache/o/seven.zig", "junk")

    {files, _skipped} = Walker.collect(root)

    rels = files |> Enum.map(& &1.rel_path) |> Enum.sort()

    assert rels == [
             "app/three.kt",
             "ios/four.swift",
             "lib/one.ex",
             "scripts/five.exs",
             "src/two.zig"
           ]

    langs = files |> Enum.map(& &1.language) |> Enum.sort()
    assert langs == [:elixir, :elixir, :kotlin, :swift, :zig]
  end

  @tag :tmp_dir
  test "oversized files are excluded", ctx do
    root = ctx.tmp_dir
    write(root, "big.zig", String.duplicate("a", 2_000_000))
    write(root, "small.zig", "fn f() void {}\n")

    {files, _} = Walker.collect(root)
    assert Enum.map(files, & &1.rel_path) == ["small.zig"]
  end

  @tag :tmp_dir
  test "symlinks are not followed", ctx do
    root = ctx.tmp_dir
    write(root, "real.ex", ":ok\n")
    File.ln_s!(root, Path.join(root, "loop"))

    {files, _} = Walker.collect(root)
    assert Enum.map(files, & &1.rel_path) == ["real.ex"]
  end

  defp write(root, rel, content) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end
end
