defmodule PoopBags.ScanPipelineTest do
  use ExUnit.Case, async: true

  alias PoopBags.ScanPipeline

  setup do
    pipeline = ScanPipeline.start(%{coverage: 0.0})
    on_exit(fn -> nil end)
    %{pipeline: pipeline}
  end

  test "a zig file rides the whole belt: load, analyze, score", %{pipeline: pipeline} do
    path =
      tmp_file(
        "tool.zig",
        "fn go(x: u32) u32 {\n    if (x > 1) {\n        return 1;\n    }\n    return 0;\n}\n"
      )

    ip =
      ScanPipeline.call(pipeline, ip_for(path, "tool.zig", :zig), 5_000)

    assert ip.failed_reason == nil
    assert [%{function_name: "go", complexity: 2, crap: 6.0}] = ip.findings
  end

  test "an elixir file gets AST analysis", %{pipeline: pipeline} do
    path =
      tmp_file(
        "gate.ex",
        "defmodule G do\n  def check(x) do\n    if x, do: :ok, else: :err\n  end\nend\n"
      )

    ip = ScanPipeline.call(pipeline, ip_for(path, "gate.ex", :elixir), 5_000)

    assert [%{function_name: "check/1", complexity: 2}] = ip.findings
  end

  test "a file that cannot parse is bagged, not dropped", %{pipeline: pipeline} do
    path = tmp_file("broken.ex", "defmodule <<<< ,,,\n")

    ip = ScanPipeline.call(pipeline, ip_for(path, "broken.ex", :elixir), 5_000)

    assert ip.failed_reason =~ "parse"
    assert ip.findings == []
  end

  test "a missing file is bagged with a reason", %{pipeline: pipeline} do
    ip =
      ScanPipeline.call(pipeline, ip_for("/nonexistent/nope.zig", "nope.zig", :zig), 5_000)

    assert ip.failed_reason != nil
  end

  test "coverage flows from pipeline options into the CRAP score" do
    pipeline = ScanPipeline.start(%{coverage: 1.0})

    path =
      tmp_file(
        "tool.zig",
        "fn go(x: u32) u32 {\n    if (x > 1) {\n        return 1;\n    }\n    return 0;\n}\n"
      )

    ip = ScanPipeline.call(pipeline, ip_for(path, "tool.zig", :zig), 5_000)
    assert [%{crap: 2.0}] = ip.findings

    ScanPipeline.stop(pipeline)
  end

  test "many concurrent calls ride the belt", %{pipeline: pipeline} do
    paths =
      for i <- 1..30 do
        tmp_file(
          "many_#{i}.zig",
          "fn f#{i}(x: u32) u32 {\n    if (x > #{i}) {\n        return 1;\n    }\n    return 0;\n}\n"
        )
      end

    results =
      paths
      |> Task.async_stream(
        &ScanPipeline.call(pipeline, ip_for(&1, Path.basename(&1), :zig), 10_000),
        max_concurrency: 10,
        timeout: 15_000
      )
      |> Enum.to_list()

    assert length(results) == 30
    assert Enum.all?(results, &match?({:ok, %{failed_reason: nil}}, &1))
  end

  defp ip_for(path, rel, lang),
    do: ScanPipeline.ip_for(%{path: path, rel_path: rel, language: lang})

  defp tmp_file(name, content) do
    dir = System.tmp_dir!()
    path = Path.join(dir, "poop_bags_test_#{System.unique_integer()}_#{name}")
    File.write!(path, content)
    path
  end
end
