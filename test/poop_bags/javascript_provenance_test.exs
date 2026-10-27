defmodule PoopBags.JavaScriptProvenanceTest do
  use PoopBags.DataCase, async: false
  alias PoopBags.{Catalog, Diff, Engine, Repo}

  @tag :tmp_dir
  test "module-scope omissions remain visible in a completed scan", %{tmp_dir: root} do
    File.write!(
      Path.join(root, "module.js"),
      "const flag = true; if (flag) console.log('module');"
    )

    {:ok, scan} = Catalog.create_scan(%{"project_path" => root})
    {:ok, scan} = Engine.run(scan)
    assert scan.functions_total == 0
    assert scan.files_skipped == 0
    assert scan.stats["analyzer_skips"] == [%{"path" => "module.js", "reason" => "module_scope"}]
  end

  @tag :tmp_dir
  test "scan records the actual pinned parser and rejects comparisons across parser versions", %{
    tmp_dir: root
  } do
    File.write!(Path.join(root, "a.ts"), "export function good(x: boolean) { return x ? 1 : 0; }")
    {:ok, baseline} = Catalog.create_scan(%{"project_path" => root})
    {:ok, baseline} = Engine.run(baseline)

    assert baseline.stats["parsers"] == [
             %{
               "parser" => "@babel/parser",
               "parser_version" => "7.29.9",
               "package_version" => "0.1.0",
               "policy" => "js-ts-ast-v1"
             }
           ]

    {:ok, current} = Catalog.create_scan(%{"project_path" => root})
    {:ok, current} = Engine.run(current)
    assert Diff.between(baseline, current).comparable

    for unknown <- [nil, ""] do
      old = %{baseline | stats: Map.put(baseline.stats, "policy", unknown)}
      new = %{current | stats: Map.put(current.stats, "policy", unknown)}
      refute Diff.between(old, new).comparable
    end

    changed = put_in(current.stats, ["parsers", Access.at(0), "parser_version"], "future")
    current = current |> Ecto.Changeset.change(stats: changed) |> Repo.update!()
    diff = Diff.between(baseline, current)
    refute diff.comparable
    refute Diff.gate_passed?(diff)
    assert Enum.any?(diff.warnings, &String.contains?(&1, "policies differ"))
  end
end
