defmodule PoopBags.GlobTest do
  use ExUnit.Case, async: true

  alias PoopBags.Glob

  test "single-segment star stays within the segment" do
    assert Glob.match?("apps/*", "apps/amrita")
    refute Glob.match?("apps/*", "apps/amrita/src/x.zig")
  end

  test "double star crosses segments" do
    assert Glob.match?("experiments/**", "experiments/hb1/a.zig")
    assert Glob.match?("experiments/**", "experiments/a.zig")
    refute Glob.match?("experiments/**", "src/a.zig")
  end

  test "prefix and suffix globs" do
    assert Glob.match?("**/*.gen.zig", "src/gen/x.gen.zig")
    assert Glob.match?("**/*.gen.zig", "x.gen.zig")
    refute Glob.match?("**/*.gen.zig", "src/x.zig")
  end

  test "question mark matches one char" do
    assert Glob.match?("file?.zig", "file1.zig")
    refute Glob.match?("file?.zig", "file10.zig")
  end

  test "regex metacharacters in patterns are escaped" do
    assert Glob.match?("a.b+c.zig", "a.b+c.zig")
    refute Glob.match?("a.b+c.zig", "axbyczig")
  end

  test "whole-path anchoring" do
    refute Glob.match?("apps", "src/apps")
    assert Glob.match?("apps", "apps")
  end
end
