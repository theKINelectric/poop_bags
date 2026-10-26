defmodule PoopBags.CoverageTest do
  use ExUnit.Case, async: true

  alias PoopBags.Analysis.Finding
  alias PoopBags.Coverage

  describe "LCOV parsing" do
    test "SF/DA records become line maps keyed by relative path" do
      lcov = """
      TN:
      SF:lib/my_app/gates.ex
      FN:10,20
      DA:11,3
      DA:12,0
      DA:15,7
      LF:3
      LH:2
      end_of_record
      SF:./src/tool.zig
      DA:2,1
      end_of_record
      """

      assert {:ok, files, "lcov"} = Coverage.parse(lcov, "lcov.info")
      assert files["lib/my_app/gates.ex"] == %{11 => 3, 12 => 0, 15 => 7}
      assert files["src/tool.zig"] == %{2 => 1}
    end

    test "duplicate records for the same file sum their counts" do
      lcov = """
      SF:a.zig
      DA:2,1
      end_of_record
      SF:a.zig
      DA:2,4
      DA:3,0
      end_of_record
      """

      assert {:ok, files, "lcov"} = Coverage.parse(lcov, "lcov.info")
      assert files["a.zig"] == %{2 => 5, 3 => 0}
    end

    test "absolute report paths align onto the project's files" do
      lcov = """
      SF:/build/elsewhere/src/a.zig
      DA:1,2
      end_of_record
      """

      assert {:ok, files, "lcov"} = Coverage.parse(lcov, "lcov.info")
      aligned = Coverage.align(files, ["src/a.zig", "lib/b.ex"])
      assert aligned["src/a.zig"] == %{1 => 2}
    end

    test "ambiguous suffixes keep their original key" do
      files = %{"ci/build/lib/a.ex" => %{1 => 1}}

      aligned = Coverage.align(files, ["lib/a.ex", "build/lib/a.ex"])
      # both known paths suffix-match → ambiguous → untouched
      assert aligned == files
    end
  end

  describe "ExCoveralls JSON parsing" do
    test "line-indexed counts become line maps (nil = not executable)" do
      json =
        Jason.encode!(%{
          "coverage" => %{
            "files" => [
              %{"name" => "lib/gates.ex", "coverage" => [nil, 0, 3, nil, 1]}
            ]
          }
        })

      assert {:ok, files, "ex_coveralls"} = Coverage.parse(json, "cover.json")
      assert files["lib/gates.ex"] == %{2 => 0, 3 => 3, 5 => 1}
    end
  end

  test "unknown format is an error" do
    assert {:error, message} = Coverage.parse("hello there", "x.info")
    assert message =~ "unrecognized coverage format"
  end

  describe "attach/2" do
    test "measures covered/executable within a function's span" do
      findings = [%Finding{function_name: "a/0", line: 1, end_line: 10, complexity: 3}]

      # 3 executable lines in span, 2 covered
      lines = %{2 => 1, 3 => 5, 4 => 0}

      [%{coverage: coverage, coverage_source: source}] = Coverage.attach(findings, lines)
      assert coverage == (2 / 3) |> Float.round(4)
      assert source == "measured"
    end

    test "a line belongs to the innermost span, not its container" do
      findings = [
        %Finding{function_name: "outer/0", line: 1, end_line: 30, complexity: 2},
        %Finding{function_name: "inner/0", line: 10, end_line: 15, complexity: 2}
      ]

      # line 12 is inside both; it must credit only inner
      lines = %{12 => 1, 20 => 1, 21 => 0}

      [outer, inner] = Coverage.attach(findings, lines)

      assert inner.coverage == 1.0
      assert outer.coverage == 0.5
    end

    test "functions the report never mentions are unknown, not zero" do
      findings = [
        %Finding{function_name: "seen/0", line: 1, end_line: 5, complexity: 1},
        %Finding{function_name: "unseen/0", line: 10, end_line: 15, complexity: 1}
      ]

      [seen, unseen] = Coverage.attach(findings, %{2 => 1})

      assert seen.coverage_source == "measured"
      assert unseen.coverage_source == "unknown"
      assert unseen.coverage == nil
    end

    test "no report data for the file marks everything unknown" do
      findings = [%Finding{function_name: "a/0", line: 1, end_line: 5, complexity: 1}]
      [%{coverage_source: "unknown"}] = Coverage.attach(findings, %{})
    end
  end
end
