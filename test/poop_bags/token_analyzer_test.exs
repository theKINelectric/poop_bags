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

  describe "rust" do
    test "if/for/while/loop/&&/||/? counted; else not" do
      src = """
      fn transform(input: &[u8]) -> Result<usize, Error> {
          if input.len() > 10 {
              return Err(Error::TooLarge);
          }
          let mut i = 0;
          while i < input.len() {
              if input[i] == b'\\r' && i + 1 < input.len() {
                  i += 1;
              }
          }
          let x = lookup(input).or_else(fallback)?;
          let y = if i > 0 { i } else { 0 };
          for _ in 0..x {
              loop {
                  if done() { break; }
              }
          }
          Ok(i)
      }
      """

      # if, while, if, &&, ?, if, for, loop, if = 9 → complexity 10
      findings = analyze(src, :rust)
      assert complexity_of(findings, "transform") == 10
    end

    test "match counts arms, not the keyword" do
      src = """
      fn pick(x: u8) -> char {
          match x {
              1 => 'a',
              2 | 3 => 'b',
              _ => 'z',
          }
      }
      """

      # `|` or-patterns are single pipes — only the three `=>` arms count
      assert complexity_of(analyze(src, :rust), "pick") == 4
    end

    test "match guards contribute their if" do
      src = """
      fn f(x: i32) -> i32 {
          match x {
              n if n > 0 => 1,
              _ => 0,
          }
      }
      """

      # 2 arms + guard if = 3 → complexity 4
      assert complexity_of(analyze(src, :rust), "f") == 4
    end

    test "comments, strings and raw strings never counted" do
      src = ~S"""
      /// doc: if (x) while (y)
      fn f() -> i32 {
          // if (a) && (b)
          let s = "for (i) => loop";
          let r = r#"if (z) || w =>"#;
          let r2 = r##"raw "quoted" still raw"##;
          /* nested /* if */ comment => */
          0
      }
      """

      assert complexity_of(analyze(src, :rust), "f") == 1
    end

    test "lifetimes don't eat the signature or the body" do
      src = """
      fn longest<'a>(x: &'a str, y: &'a str) -> &'a str {
          if x.len() > y.len() {
              x
          } else {
              y
          }
      }

      fn tick(c: char) -> bool {
          c.is_ascii() || c == 'x'
      }
      """

      findings = analyze(src, :rust)
      assert complexity_of(findings, "longest") == 2
      assert complexity_of(findings, "tick") == 2
    end

    test "empty-parameter closures don't count as boolean or" do
      src = """
      fn f(xs: Vec<i32>) -> Vec<i32> {
          let d = xs.iter().max().unwrap_or_else(|| 0);
          let g = move || xs.len();
          xs.iter().map(|x| x * 2).filter(|x| *x > 0).collect()
      }
      """

      assert complexity_of(analyze(src, :rust), "f") == 1
    end

    test "boolean or counts" do
      src = """
      fn f(a: bool, b: bool) -> bool {
          if a || b { true } else { false }
      }
      """

      # if + || = 2 → complexity 3
      assert complexity_of(analyze(src, :rust), "f") == 3
    end

    test "try operator counts, ?Sized bounds don't" do
      src = """
      fn load<T: ?Sized>() -> Result<u8, Err> {
          let v = read()?;
          let w = v.checked_add(1).ok_or(Err::Math)?;
          Ok(w)
      }
      """

      assert complexity_of(analyze(src, :rust), "load") == 3
    end

    test "trait signatures get no body" do
      src = """
      trait Repo {
          fn find(&self, id: u64) -> u64;
          fn name(&self) -> &str;
      }
      fn real() {}
      """

      findings = analyze(src, :rust)
      assert Enum.map(findings, & &1.function_name) == ["real"]
    end

    test "impl groups methods under the implemented type" do
      src = """
      struct Point { x: i32 }

      impl Point {
          fn shift(&mut self, dx: i32) {
              if dx > 0 { self.x += dx; }
          }
      }

      impl Display for Point {
          fn fmt(&self) -> String {
              format!("{}", self.x)
          }
      }
      """

      findings = analyze(src, :rust)
      assert Enum.find(findings, &(&1.function_name == "shift")).module_name == "Point"
      assert Enum.find(findings, &(&1.function_name == "fmt")).module_name == "Point"
    end

    test "generics and fn-pointer types don't create phantom functions" do
      src = """
      type Callback = fn(i32) -> i32;
      fn apply<T, const N: usize>(f: Callback, xs: [T; N]) -> i32 {
          if N > 0 { f(0) } else { 0 }
      }
      """

      findings = analyze(src, :rust)
      assert Enum.map(findings, & &1.function_name) == ["apply"]
      assert complexity_of(findings, "apply") == 2
    end

    test "nested functions don't double count" do
      src = """
      fn outer() {
          fn helper(x: u32) -> u32 {
              if x > 1 { x } else { 0 }
          }
          let _ = helper;
      }
      """

      findings = analyze(src, :rust)
      assert complexity_of(findings, "outer") == 1
      assert complexity_of(findings, "helper") == 2
    end

    test "mod declarations without bodies don't swallow" do
      src = """
      mod sibling;
      fn top() { if true {} }
      """

      findings = analyze(src, :rust)
      assert Enum.find(findings, &(&1.function_name == "top")).module_name == ""
    end
  end
end
