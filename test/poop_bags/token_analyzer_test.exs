defmodule PoopBags.TokenAnalyzerTest do
  use ExUnit.Case, async: true

  alias PoopBags.TokenAnalyzer

  defp analyze(source, lang), do: TokenAnalyzer.analyze(source, lang)

  defp complexity_of(findings, name) do
    Enum.find(findings, &(&1.function_name == name)).complexity
  end

  describe "zig" do
    test "if/while/for/and/or/orelse/catch counted; else not" do
      src = """
      fn transform(input: []const u8) Error!Result {
          if (input.len > 10) return error.TooLarge;
          var i: usize = 0;
          while (i < input.len) : (i += 1) {
              if (input[i] == '\\r' and i + 1 < input.len) i += 1;
          }
          const x = null orelse return error.Nil;
          const y = foo() catch return error.Foo;
          return .{};
      }
      """

      # tokens: if, while, if, and, orelse, catch = 6 → complexity 7
      findings = analyze(src, :zig)
      assert complexity_of(findings, "transform") == 7
    end

    test "switch counts prongs, not the keyword" do
      src = """
      fn pick(x: u8) u8 {
          switch (x) {
              1 => 'a',
              2, 3 => 'b',
              else => 'z',
          }
      }
      """

      assert complexity_of(analyze(src, :zig), "pick") == 4
    end

    test "comments and strings never counted" do
      src = """
      /// doc comment: if (x) while (y)
      fn f() void {
          // if (a) and (b)
          const s = "for (i) =>";
          _ = s;
      }
      """

      assert complexity_of(analyze(src, :zig), "f") == 1
    end

    test "nested functions do not double count" do
      src = """
      fn outer() void {
          const inner = struct {
              fn helper(x: u32) u32 {
                  if (x > 1) {
                      return x;
                  } else {
                      return 0;
                  }
              }
          };
          _ = inner;
      }
      """

      findings = analyze(src, :zig)
      assert complexity_of(findings, "outer") == 1
      assert complexity_of(findings, "helper") == 2
    end

    test "extern declarations get no body" do
      src = "extern fn printf(format: [*:0]const u8, ...) c_int;\nfn real() void {}"
      findings = analyze(src, :zig)
      assert Enum.map(findings, & &1.function_name) == ["real"]
    end

    test "multiline string continuation not counted" do
      src = """
      fn f() void {
          const s =
          \\\\if (x) while (y) switch (z)
          \\\\for (a)
          ;
          _ = s;
      }
      """

      assert complexity_of(analyze(src, :zig), "f") == 1
    end

    test "inline error sets do not eat the body" do
      src = """
      fn f(x: u32) error{TooBig, Bad}!u32 {
          if (x > 1) {
              return error.TooBig;
          }
          return 0;
      }
      """

      assert complexity_of(analyze(src, :zig), "f") == 2
    end

    test "module names come from struct declarations" do
      src = """
      pub const Store = struct {
          pub fn open() !void {}
      };
      fn main() void {}
      """

      findings = analyze(src, :zig)
      assert Enum.map(findings, & &1.module_name) == ["Store", ""]
    end
  end

  describe "kotlin" do
    test "if/for/while/catch and boolean operators counted" do
      src = """
      class Box {
          fun sort(items: List<Int>): Int {
              var n = 0
              for (i in items) {
                  if (i > 0 && i < 100) n += 1
              }
              while (n > 10) n -= 1
              try {
                  risky()
              } catch (e: Exception) {
                  n = -1
              }
              return n
          }
      }
      """

      assert complexity_of(analyze(src, :kotlin), "sort") == 6
    end

    test "when counts arms, not the keyword; type arrows excluded" do
      src = """
      fun pick(x: Int): Int = when (x) {
          1 -> 10
          2 -> 20
          else -> 0
      }

      fun typeArrow(f: (Int) -> Int): Int = f(1)
      """

      findings = analyze(src, :kotlin)
      assert complexity_of(findings, "pick") == 4
      assert complexity_of(findings, "typeArrow") == 1
    end

    test "expression body ends at its line; next fun untouched" do
      src = """
      fun one(): Int = compute(1) + compute(2)

      fun two(): Int {
          return if (one() > 0) 1 else 0
      }
      """

      findings = analyze(src, :kotlin)
      assert complexity_of(findings, "one") == 1
      assert complexity_of(findings, "two") == 2
    end

    test "external declarations get no body" do
      src = "class C {\n    private external fun nativeThing()\n    fun real(): Int = 1\n}"
      findings = analyze(src, :kotlin)
      assert Enum.map(findings, & &1.function_name) == ["real"]
    end

    test "local functions reported separately" do
      src = """
      fun outer(x: Int): Int {
          fun inner(y: Int): Int {
              return if (y > 0) y else -y
          }
          return inner(x)
      }
      """

      findings = analyze(src, :kotlin)
      assert complexity_of(findings, "outer") == 1
      assert complexity_of(findings, "inner") == 2
    end

    test "expression body starting on the next line still counts" do
      src = "fun pick(x: Int): String =\n    if (x > 0) \"big\" else \"small\""

      assert complexity_of(analyze(src, :kotlin), "pick") == 2
    end

    test "parameter default = is not an expression body" do
      src = "fun f(x: Int = 5): Int {\n    return if (x > 0) x else -x\n}"

      assert complexity_of(analyze(src, :kotlin), "f") == 2
    end

    test "nested generics in declarations are found" do
      src = "class Box {\n    fun <T : Comparable<T>> max(a: T, b: T): T = if (a > b) a else b\n}"

      findings = analyze(src, :kotlin)
      assert complexity_of(findings, "max") == 2
    end

    test "elvis operator counts" do
      src = "fun name(s: String?): String = s ?: \"anon\""
      assert complexity_of(analyze(src, :kotlin), "name") == 2
    end

    test "triple-quoted regex literal does not leak tokens" do
      src = ~s|fun rx(): Regex = """(\d+if(x)&&y)""".toRegex()|
      assert complexity_of(analyze(src, :kotlin), "rx") == 1
    end
  end

  describe "swift" do
    test "if/guard/for/while/catch and operators counted" do
      src = """
      struct Scanner {
          func count(_ items: [Int]) -> Int {
              var n = 0
              for i in items where i > 0 {
                  if i % 2 == 0 || i % 3 == 0 { n += 1 }
              }
              guard n > 0 else { return 0 }
              while n > 10 { n -= 1 }
              do {
                  try risky()
              } catch {
                  n = -1
              }
              return n
          }
      }
      """

      assert complexity_of(analyze(src, :swift), "count") == 8
    end

    test "switch counts case arms and default" do
      src = """
      func pick(_ x: Int) -> Int {
          switch x {
          case 1:
              return 10
          case 2, 3:
              return 20
          default:
              return 0
          }
      }
      """

      assert complexity_of(analyze(src, :swift), "pick") == 4
    end

    test "protocol requirements do not steal the next body" do
      src = """
      protocol Repo {
          func find(id: Int) -> Int
      }

      class Impl: Repo {
          func find(id: Int) -> Int {
              if id > 0 { return 1 }
              return 0
          }
      }
      """

      findings = analyze(src, :swift)
      # requirement has no body span; impl has its own
      impl = Enum.find(findings, &(&1.function_name == "find" && &1.module_name == "Impl"))
      assert impl.complexity == 2
      assert Enum.count(findings, &(&1.function_name == "find")) == 1
    end

    test "ternary and nil coalescing count" do
      src = """
      func label(_ x: Int?) -> String {
          let n = x ?? 0
          return n > 0 ? "big" : "small"
      }
      """

      assert complexity_of(analyze(src, :swift), "label") == 3
    end

    test "inits are functions too" do
      src = """
      class Point {
          var x = 0
          init?(v: Int) {
              guard v > 0 else { return nil }
              x = v
          }
      }
      """

      assert complexity_of(analyze(src, :swift), "init") == 2
    end

    test "#if compiler directives not counted" do
      src = """
      func f() -> Int {
      #if DEBUG
          return 1
      #else
          return 2
      #endif
      }
      """

      assert complexity_of(analyze(src, :swift), "f") == 1
    end
  end
end
