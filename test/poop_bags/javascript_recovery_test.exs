defmodule PoopBags.JavaScriptRecoveryTest do
  use PoopBags.DataCase, async: false
  alias PoopBags.{Analysis, Catalog, Coverage, Engine}

  @tag :tmp_dir
  test "a broken neighbor fails visibly without erasing valid TypeScript findings", %{
    tmp_dir: root
  } do
    File.write!(Path.join(root, "a.ts"), "export function good(x: boolean) { return x ? 1 : 0; }")
    File.write!(Path.join(root, "b.ts"), "export function broken( {")
    {:ok, scan} = Catalog.create_scan(%{"project_path" => root})
    assert {:ok, result} = Engine.run(scan)
    assert result.files_failed == 1
    assert result.functions_total == 1
    assert hd(Catalog.all_findings(result)).function_name == "good"
  end

  test "original-source LCOV measures uniquely owned TS lines while shared boundary lines stay unknown" do
    source = """
    export function outer(x: boolean) {
      if (x) return 1;
      const inner = (y: boolean) => y ? 1 : 0;
      return inner(x);
    }
    """

    {:ok, findings} = Analysis.analyze(source, :typescript, path: "src/a.ts")
    measured = Coverage.attach(findings, %{2 => 1, 3 => 1, 4 => 0})
    outer = Enum.find(measured, &(&1.function_name == "outer"))
    inner = Enum.find(measured, &String.ends_with?(&1.function_name, ".inner"))
    assert outer.coverage_source == "measured"
    assert outer.coverage == 0.5
    assert inner.coverage_source == "unknown"
    assert inner.coverage == nil
  end

  test "separate body lines give the nested function exclusive measured coverage" do
    source = """
    function outer() {
      const inner = (x) => {
        if (x) return 1;
        return 0;
      };
      return inner(true);
    }
    """

    {:ok, findings} = Analysis.analyze(source, :javascript, path: "a.js")
    measured = Coverage.attach(findings, %{3 => 1, 4 => 0, 6 => 1})
    outer = Enum.find(measured, &(&1.function_name == "outer"))
    inner = Enum.find(measured, &String.ends_with?(&1.function_name, ".inner"))
    assert outer.coverage == 1.0
    assert inner.coverage == 0.5
  end

  @tag :tmp_dir
  test "CLI fails incomplete parses instead of recording a false clean pass", %{tmp_dir: root} do
    File.write!(Path.join(root, "broken.ts"), "export function broken( {")

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert catch_exit(Mix.Tasks.PoopBags.Ci.run(["--path", root, "--against", "none"])) ==
                 {:shutdown, 2}
      end)

    assert output =~ "failed"
  end

  @tag :tmp_dir
  test "a partial scan cannot become a passing comparison baseline", %{tmp_dir: root} do
    File.write!(Path.join(root, "good.ts"), "export function good() { return true; }")
    File.write!(Path.join(root, "bad.ts"), "export function broken( {")
    {:ok, before} = Catalog.create_scan(%{"project_path" => root})
    {:ok, before} = Engine.run(before)
    File.write!(Path.join(root, "bad.ts"), "export function fixed() { return true; }")
    {:ok, after_scan} = Catalog.create_scan(%{"project_path" => root})
    {:ok, after_scan} = Engine.run(after_scan)
    diff = PoopBags.Diff.between(before, after_scan)
    refute diff.comparable
    refute PoopBags.Diff.gate_passed?(diff)
    assert Enum.any?(diff.warnings, &String.contains?(&1, "failed"))
  end

  @tag :tmp_dir
  test "CLI fails a violating regression even when max rows hides it", %{tmp_dir: root} do
    file = Path.join(root, "many.ts")

    before_source =
      branches("hidden", 3) <>
        Enum.map_join(1..26, "\n", &branches("clean_#{&1}", 0))

    File.write!(file, before_source)
    {:ok, baseline} = Catalog.create_scan(%{"project_path" => root})
    {:ok, baseline} = Engine.run(baseline)

    File.write!(
      file,
      branches("hidden", 4) <>
        Enum.map_join(1..26, "\n", &branches("clean_#{&1}", 3))
    )

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          assert catch_exit(
                   Mix.Tasks.PoopBags.Ci.run([
                     "--path",
                     root,
                     "--against",
                     to_string(baseline.id),
                     "--max-rows",
                     "25",
                     "--format",
                     "json"
                   ])
                 ) == {:shutdown, 1}
        end)
      end)

    assert stderr =~ "gate FAIL"
  end

  @tag :tmp_dir
  test "explicit malformed baseline IDs fail instead of selecting latest", %{tmp_dir: root} do
    valid_baseline(root)

    for id <- ["notanumber", "12oops", "0", "-1", "99999999999999999999999999"] do
      assert_baseline_error(root, id)
    end
  end

  @tag :tmp_dir
  test "explicit missing baseline ID fails instead of selecting latest", %{tmp_dir: root} do
    valid_baseline(root)
    assert_baseline_error(root, "99999999")
  end

  @tag :tmp_dir
  test "explicit expired baseline ID fails instead of selecting latest", %{tmp_dir: root} do
    expired = valid_baseline(root)

    expired
    |> Ecto.Changeset.change(details_expired_at: DateTime.utc_now())
    |> PoopBags.Repo.update!()

    valid_baseline(root)
    assert_baseline_error(root, to_string(expired.id), "expired")
  end

  @tag :tmp_dir
  test "explicit unfinished baseline ID fails instead of selecting latest", %{tmp_dir: root} do
    valid_baseline(root)
    {:ok, queued} = Catalog.create_scan(%{"project_path" => root})
    assert_baseline_error(root, to_string(queued.id), "not finished")
  end

  @tag :tmp_dir
  test "omitted and latest baselines remain automatic while none skips comparison", %{
    tmp_dir: root
  } do
    baseline = valid_baseline(root)

    for against <- [[], ["--against", "latest"]] do
      expected = Catalog.latest_baseline(%{baseline | id: -1})

      stdout =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = Mix.Tasks.PoopBags.Ci.run(["--path", root, "--format", "json"] ++ against)
        end)

      [report | _] = String.split(stdout, "\n", trim: true)
      assert Jason.decode!(report)["baseline_id"] == expected.id
      assert stdout =~ "gate PASS"
    end

    stdout =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = Mix.Tasks.PoopBags.Ci.run(["--path", root, "--against", "none"])
      end)

    assert stdout =~ "no baseline"
    assert stdout =~ "Gate: PASS"
  end

  defp branches(name, count) do
    body = String.duplicate("if (flag) {} ", count)
    "export function #{name}(flag: boolean) { #{body}return flag; }\n"
  end

  defp valid_baseline(root) do
    File.write!(Path.join(root, "good.ts"), "export function good() { return true; }")
    {:ok, scan} = Catalog.create_scan(%{"project_path" => root})
    {:ok, scan} = Engine.run(scan)
    scan
  end

  defp assert_baseline_error(root, id, reason \\ "baseline") do
    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          assert catch_exit(Mix.Tasks.PoopBags.Ci.run(["--path", root, "--against", id])) ==
                   {:shutdown, 2}
        end)
      end)

    assert stderr =~ "baseline"
    assert stderr =~ reason
    refute stderr =~ "using latest"
  end
end
