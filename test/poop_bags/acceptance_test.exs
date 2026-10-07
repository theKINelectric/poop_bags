defmodule PoopBags.AcceptanceTest do
  @moduledoc """
  The phase-2 acceptance scenario, end to end:

  scan a project with config and coverage attached → refactor one hotspot →
  rescan → diff against the baseline → the same explained result through the
  engine (web) and the CI gate.
  """

  use PoopBags.DataCase, async: false

  alias PoopBags.Catalog
  alias PoopBags.Diff
  alias PoopBags.Engine

  # The pre-refactor hotspot: 10 branch tokens → cx 11 → CRAP 132 at 0%
  # coverage; the ingested LCOV covers part of it.
  @before_zig """
  fn beast(a: u32, b: u32) u32 {
      var total: u32 = 0;
      if (a > 1 and b > 1) {
          total += 1;
      }
      if (a > 2 and b > 2) {
          total += 2;
      }
      if (a > 3) {
          total += 3;
      }
      if (a > 4) {
          total += 4;
      }
      var i: u32 = 0;
      while (i < a) : (i += 1) {
          total += 1;
      }
      while (total > 100) {
          total -= 1;
      }
      for (0..b) |_| {
          total += 1;
      }
      const safe = total orelse 0;
      return safe;
  }

  fn calm() void {}
  """

  # The refactor: beast keeps its signature (identity preserved) but sheds
  # half its branching to a new helper function.
  @after_zig """
  fn beast(a: u32, b: u32) u32 {
      var total: u32 = 0;
      total += tally_early(a, b);
      if (a > 3) {
          total += 3;
      }
      if (a > 4) {
          total += 4;
      }
      var i: u32 = 0;
      while (i < a) : (i += 1) {
          total += 1;
      }
      for (0..b) |_| {
          total += 1;
      }
      return total;
  }

  fn tally_early(a: u32, b: u32) u32 {
      var n: u32 = 0;
      if (a > 1 and b > 1) {
          n += 1;
      }
      if (a > 2 and b > 2) {
          n += 2;
      }
      return n;
  }

  fn calm() void {}
  """

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(PoopBags.Repo, {:shared, self()})

    root =
      Path.join([
        System.tmp_dir!(),
        "poop_bags_acceptance_#{:erlang.unique_integer([:positive])}"
      ])

    File.mkdir_p!(Path.join(root, "src"))
    File.mkdir_p!(Path.join(root, "generated"))
    File.mkdir_p!(Path.join(root, "lib"))

    # Project config: exclude generated code, attach coverage, low threshold
    # so the hotspot is a violation before the refactor and clean after.
    File.write!(Path.join(root, ".poopbags.json"), ~s({
      "exclude": ["generated/**"],
      "coverage_report": "cover/lcov.info",
      "threshold": 30
    }))

    File.write!(Path.join(root, "src/tool.zig"), @before_zig)

    # Excluded from the scan by config — must never appear in findings.
    File.write!(
      Path.join(root, "generated/never.zig"),
      "fn excluded() void {\n    if (true) {}\n}"
    )

    File.write!(Path.join(root, "lib/gates.ex"), """
    defmodule Subject.Gates do
      def check(x) do
        if x == :go, do: :ok, else: :err
      end
    end
    """)

    # Coverage: most of beast's lines executed, calm untouched.
    File.mkdir_p!(Path.join(root, "cover"))

    # Sparse on purpose: the hotspot must stay a violation before the
    # refactor (measured coverage ~0.4 → CRAP ~37 > threshold 30).
    write_lcov(root, "src/tool.zig", [
      {3, 1},
      {4, 0},
      {5, 0},
      {7, 0},
      {8, 0},
      {9, 0},
      {11, 1},
      {12, 0},
      {14, 0},
      {17, 1},
      {18, 5},
      {19, 5},
      {22, 1},
      {23, 0},
      {24, 0},
      {27, 1},
      {28, 0}
    ])

    # the executable line of check/1 is its `if` (line 3 of the file)
    write_lcov(root, "lib/gates.ex", [{3, 1}])

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "config + coverage + refactor + diff, web engine and CI agree", %{root: root} do
    # ---- scan A: baseline
    {:ok, scan_a} = Catalog.create_scan(%{"project_path" => root, "label" => "baseline"})

    assert {:ok, scan_a} = Engine.run(scan_a, caller_pool: 4)
    assert scan_a.status == "done"
    assert scan_a.threshold == 30.0
    assert scan_a.config["source"] == ".poopbags.json"

    # exclusions took effect: generated/never.zig is absent
    findings_a = Catalog.all_findings(scan_a)
    refute Enum.any?(findings_a, &String.starts_with?(&1.path, "generated/"))

    beast = Enum.find(findings_a, &(&1.function_name == "beast"))
    assert beast.complexity == 11
    assert beast.coverage_source == "measured"
    assert beast.coverage > 0.4
    # measured coverage pulls CRAP well below the assumed 132
    assert beast.crap < 132.0
    assert beast.crap > 30.0

    gates = Enum.find(findings_a, &(&1.function_name == "check/1"))
    assert gates.coverage_source == "measured"

    calm = Enum.find(findings_a, &(&1.function_name == "calm"))
    # LCOV says nothing about calm() → unknown → assumed fallback
    assert calm.coverage_source == "assumed"

    # ---- the refactor: split the hotspot, run the tests again (new LCOV)
    File.write!(Path.join(root, "src/tool.zig"), @after_zig)

    write_lcov(root, "src/tool.zig", [
      {3, 1},
      {4, 1},
      {6, 1},
      {7, 0},
      {8, 0},
      {11, 1},
      {12, 2},
      {13, 2},
      {16, 1},
      {17, 1},
      {18, 1},
      {21, 1},
      {23, 1},
      {24, 1},
      {26, 1}
    ])

    # ---- scan B: after
    {:ok, scan_b} = Catalog.create_scan(%{"project_path" => root, "label" => "after refactor"})

    assert {:ok, scan_b} = Engine.run(scan_b, caller_pool: 4)

    findings_b = Catalog.all_findings(scan_b)
    beast_b = Enum.find(findings_b, &(&1.function_name == "beast"))
    helper_b = Enum.find(findings_b, &(&1.function_name == "tally_early"))

    assert beast_b.complexity == 5
    assert helper_b.complexity == 5
    # the refactor + coverage pulled beast under the violation threshold
    assert beast_b.crap <= 30.0

    # ---- diff: the refactor story
    diff = Diff.between(scan_a, scan_b)

    assert diff.comparable
    assert diff.threshold == 30.0

    outcomes =
      diff.rows
      |> Map.new(&{elem(&1.identity, 3), &1.outcome})

    assert outcomes["beast"] == :resolved
    assert outcomes["tally_early"] == :introduced
    assert outcomes["calm"] == :unchanged
    assert outcomes["check/1"] == :unchanged

    # introduced helper is NOT a violation (cx 3, covered)
    helper_row = Enum.find(diff.rows, &(elem(&1.identity, 3) == "tally_early"))
    refute helper_row.violation

    # ---- the gate: the refactor passed it
    assert Diff.gate_passed?(diff)

    # ---- CI agrees: a third identical scan against scan_b passes the gate
    assert :ok =
             Mix.Tasks.PoopBags.Ci.run([
               "--path",
               root,
               "--against",
               Integer.to_string(scan_b.id),
               "--format",
               "json"
             ])
  end

  test "CI gate fails when a refactor introduces a violation", %{root: root} do
    # baseline
    {:ok, scan_a} = Catalog.create_scan(%{"project_path" => root, "label" => "ci baseline"})
    {:ok, scan_a} = Engine.run(scan_a, caller_pool: 4)

    # make it worse: add a rotting function with no coverage
    File.write!(
      Path.join(root, "src/tool.zig"),
      @before_zig <>
        "\nfn rot() u32 {\n    var t: u32 = 0;\n    if (t > 1) t += 1;\n    if (t > 2) t += 1;\n    if (t > 3) t += 1;\n    if (t > 4) t += 1;\n    if (t > 5) t += 1;\n    if (t > 6) t += 1;\n    return t;\n}\n"
    )

    assert catch_exit(
             Mix.Tasks.PoopBags.Ci.run([
               "--path",
               root,
               "--against",
               Integer.to_string(scan_a.id)
             ])
           ) == {:shutdown, 1}
  end

  # ---------------------------------------------------------------- helpers

  defp write_lcov(root, path, das) do
    file = Path.join(root, "cover/lcov.info")

    record =
      ["SF:#{path}"] ++
        Enum.map(das, fn {line, count} -> "DA:#{line},#{count}" end) ++
        ["end_of_record", ""]

    File.write!(file, ((File.exists?(file) && File.read!(file)) || "") <> Enum.join(record, "\n"))
  end
end
