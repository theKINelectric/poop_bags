defmodule PoopBags.JavaScriptReportsTest do
  use PoopBags.DataCase, async: false
  alias PoopBags.{Catalog, Engine}

  @tag :tmp_dir
  test "first Markdown report records parser versions and module scope exclusions", %{
    tmp_dir: root
  } do
    subject(root)
    output = cli(root, ["--against", "none", "--format", "markdown"])
    assert_markdown_metadata(output)
    assert output =~ "Gate: PASS"
  end

  @tag :tmp_dir
  test "diff Markdown report records parser versions and module scope exclusions", %{
    tmp_dir: root
  } do
    subject(root)
    baseline = baseline(root)
    output = cli(root, ["--against", to_string(baseline.id), "--format", "markdown"])
    assert_markdown_metadata(output)
    assert output =~ "gate PASS"
  end

  @tag :tmp_dir
  test "first JSON report is JSON and records parser metadata without inventing a baseline", %{
    tmp_dir: root
  } do
    subject(root)
    output = cli(root, ["--against", "none", "--format", "json"])
    report = first_json(output)
    assert report["baseline_id"] == nil
    assert report["gate_passed"] == true
    assert_json_metadata(report)
  end

  @tag :tmp_dir
  test "diff JSON report records exact parser versions and module scope exclusions", %{
    tmp_dir: root
  } do
    subject(root)
    baseline = baseline(root)
    output = cli(root, ["--against", to_string(baseline.id), "--format", "json"])
    report = first_json(output)
    assert report["baseline_id"] == baseline.id
    assert report["gate_passed"] == true
    assert_json_metadata(report)
  end

  defp subject(root) do
    File.write!(
      Path.join(root, "main.ts"),
      "const moduleGate = true;\nexport function eligible(age: number) { return age >= 18; }\n"
    )
  end

  defp baseline(root) do
    {:ok, scan} = Catalog.create_scan(%{"project_path" => root})
    {:ok, scan} = Engine.run(scan)
    scan
  end

  defp cli(root, options) do
    ExUnit.CaptureIO.capture_io(fn ->
      assert :ok = Mix.Tasks.PoopBags.Ci.run(["--path", root] ++ options)
    end)
  end

  defp first_json(output) do
    [line | _] = String.split(output, "\n", trim: true)
    Jason.decode!(line)
  end

  defp assert_markdown_metadata(output) do
    assert output =~ "@babel/parser"
    assert output =~ "7.29.9"
    assert output =~ "0.1.0"
    assert output =~ "js-ts-ast-v1"
    assert output =~ "main.ts"
    assert output =~ "module_scope"
  end

  defp assert_json_metadata(report) do
    assert is_binary(report["policy"])

    assert [
             %{
               "parser" => "@babel/parser",
               "parser_version" => "7.29.9",
               "package_version" => "0.1.0",
               "policy" => "js-ts-ast-v1"
             }
           ] = report["parsers"]

    assert [%{"path" => "main.ts", "reason" => "module_scope"}] = report["analyzer_skips"]
  end
end
