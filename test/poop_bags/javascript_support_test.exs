defmodule PoopBags.JavaScriptSupportTest do
  use PoopBags.DataCase, async: false
  alias PoopBags.{Analysis, Coverage, Engine, Catalog, Diff, Languages, Walker}

  test "recognizes the JS family and refuses declaration files" do
    for ext <- ~w(.js .jsx .mjs .cjs),
        do: assert(Languages.language_for("code" <> ext) == :javascript)

    for ext <- ~w(.ts .tsx .mts .cts),
        do: assert(Languages.language_for("code" <> ext) == :typescript)

    for name <- ~w(types.d.ts types.d.mts types.d.cts),
        do: assert(Languages.language_for(name) == nil)
  end

  test "AST analysis counts runtime branches and explains the same function" do
    source = "export const eligible = (age: number): boolean => age >= 18 ? true : false;"
    assert {:ok, [f]} = Analysis.analyze(source, :typescript, path: "src/check.ts")
    assert f.function_name == "eligible"
    assert f.complexity == 2

    assert %{contributions: parts} =
             PoopBags.JavaScriptAnalyzer.explain(source, :typescript, "eligible",
               path: "src/check.ts"
             )

    assert Enum.sum(Enum.map(parts, &elem(&1, 1))) == 1
  end

  test "LCOV cannot claim measured coverage for two equal same-line spans" do
    {:ok, findings} =
      Analysis.analyze("const a = () => true; const b = () => false;", :javascript,
        path: "src/two.js"
      )

    assert length(findings) == 2

    assert Enum.all?(
             Coverage.attach(findings, %{1 => 1}),
             &(&1.coverage == nil and &1.coverage_source == "unknown")
           )
  end

  test "malformed TypeScript is an explicit parser error" do
    assert {:error, _} =
             Analysis.analyze("export function broken( {", :typescript, path: "bad.ts")
  end

  @tag :tmp_dir
  test "static scan never loads imports or a subject Babel config", %{tmp_dir: root} do
    File.write!(
      Path.join(root, ".poopbags.json"),
      ~s({"languages":["typescript"],"threshold":10})
    )

    marker = Path.join(root, "EXECUTED")

    File.write!(
      Path.join(root, "babel.config.cjs"),
      "require('fs').writeFileSync(#{Jason.encode!(marker)},'oops'); module.exports={};"
    )

    File.write!(
      Path.join(root, "main.ts"),
      "import './evil.js'; export function safe(x: boolean) { return x ? 1 : 0; }"
    )

    File.write!(
      Path.join(root, "evil.js"),
      "require('fs').writeFileSync(#{Jason.encode!(marker)},'oops');"
    )

    assert {:ok, scan} = scan(root)
    assert scan.files_failed == 0
    assert scan.functions_total == 1
    refute File.exists?(marker)
  end

  @tag :tmp_dir
  test "walker skips generated framework trees and declarations", %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, ".next"))
    File.write!(Path.join(root, ".next/generated.js"), "function generated() {}")
    File.write!(Path.join(root, "types.d.ts"), "declare function x(): void;")
    File.write!(Path.join(root, "real.tsx"), "export const View=()=> <div/>;")
    {files, _} = Walker.collect(root)
    assert Enum.map(files, & &1.rel_path) == ["real.tsx"]
  end

  @tag :tmp_dir
  test "scan refactor and CI policy agree for TypeScript", %{tmp_dir: root} do
    File.write!(
      Path.join(root, ".poopbags.json"),
      ~s({"languages":["typescript"],"threshold":10})
    )

    file = Path.join(root, "gates.ts")

    File.write!(
      file,
      "export function gate(a: boolean, b: boolean) { if (a && b) return 1; if(a) return 2; return 0; }"
    )

    assert {:ok, before} = scan(root)
    assert before.stats["violations"] == 1

    File.write!(
      file,
      "export function gate(a: boolean, b: boolean) { return a ? decide(b) : 0; }\nfunction decide(b: boolean) { return b ? 1 : 2; }"
    )

    assert {:ok, after_scan} = scan(root)
    diff = Diff.between(before, after_scan)
    assert diff.comparable
    assert Diff.gate_passed?(diff)
    assert Enum.any?(diff.rows, &(&1.outcome in [:resolved, :improved]))
    assert Enum.all?(Catalog.top_findings(after_scan), &(&1.language == "typescript"))

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Task.reenable("poop_bags.ci")

        Mix.Tasks.PoopBags.Ci.run([
          "--path",
          root,
          "--against",
          to_string(after_scan.id),
          "--format",
          "json"
        ])
      end)

    assert output =~ ~s("gate_passed":true)
  end

  defp scan(root) do
    {:ok, scan} = Catalog.create_scan(%{"project_path" => root})
    Engine.run(scan)
  end
end
