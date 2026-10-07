defmodule PoopBags.SourceCleanerTest do
  use ExUnit.Case, async: true

  alias PoopBags.SourceCleaner

  defp clean(source, lang), do: SourceCleaner.clean(source, lang)

  describe "the contract: same length, same newlines" do
    test "line comments preserve length and newline positions" do
      src = "val a = 1 // if (x) && y\nval b = 2"
      out = clean(src, :kotlin)
      assert byte_size(out) == byte_size(src)
      assert newline_positions(out) == newline_positions(src)
      refute out =~ "if"
      assert out =~ "val a = 1"
    end

    test "block comments preserve length" do
      src = "x = 1 /* while (a) */ + 2"
      out = clean(src, :zig)
      assert byte_size(out) == byte_size(src)
      refute out =~ "while"
      assert out =~ "x = 1"
    end

    test "kotlin nested block comments" do
      src = "/* outer /* inner if (x) */ still comment */ val y = 1"
      out = clean(src, :kotlin)
      assert byte_size(out) == byte_size(src)
      refute out =~ "if"
      assert out =~ "val y = 1"
    end

    test "double-quoted strings blanked with escapes" do
      src = ~s{val s = "if (x) \\" quote" ; val t = 2}
      out = clean(src, :kotlin)
      assert byte_size(out) == byte_size(src)
      refute out =~ "if"
      assert out =~ "val t = 2"
    end

    test "kotlin triple-quoted strings (regex literals)" do
      src = ~s|r = """python(\d+)""".toRegex()|
      out = clean(src, :kotlin)
      assert byte_size(out) == byte_size(src)
      refute out =~ "python"
      assert out =~ ".toRegex()"
    end

    test "kotlin string templates with braces" do
      src = ~s|p("${dir("x")}") |
      out = clean(src, :kotlin)
      assert byte_size(out) == byte_size(src)
      assert String.trim(out) == "p(" <> String.duplicate(" ", 13) <> ")"
    end

    test "swift raw strings" do
      src = ~s|let r = #"while (a) "# + 1|
      out = clean(src, :swift)
      assert byte_size(out) == byte_size(src)
      refute out =~ "while"
      assert out =~ "+ 1"
    end

    test "char literals blanked" do
      src = "if (c == 'x') {"
      out = clean(src, :zig)
      assert byte_size(out) == byte_size(src)
      assert out =~ "if"
      refute out =~ "'x'"
    end

    test "unterminated string stops at end, not at swallowing code" do
      src = ~s{f("abc\ndef() if (x)}
      out = clean(src, :kotlin)
      assert byte_size(out) == byte_size(src)
      # the if on line 2 survives as code
      assert out =~ "if"
    end
  end

  describe "zig multiline strings" do
    test "continuation lines all blanked" do
      src = "const s =\n    \\\\if (x) {\n    \\\\while (y)\n;\nfn g() void {"
      out = clean(src, :zig)
      assert byte_size(out) == byte_size(src)
      refute out =~ "if"
      refute out =~ "while"
      assert out =~ "fn g() void {"
    end

    test "line starting with backslash-backslash after code stays string" do
      src = "fn f() void {\n    const s =\n        \\\\hello if (x)\n    ;\n}"
      out = clean(src, :zig)
      refute out =~ "hello"
      assert out =~ "fn f"
    end
  end

  describe "swift" do
    test "comments and strings blanked, code intact" do
      src = "func f() { // if (x)\n  let s = \"guard let x\"\n  if a && b { }\n}"
      out = clean(src, :swift)
      assert byte_size(out) == byte_size(src)
      assert out =~ "if a && b"
      refute out =~ "guard let"
    end
  end

  defp newline_positions(bin) do
    :binary.matches(bin, "\n") |> Enum.map(fn {p, _} -> p end)
  end
end
