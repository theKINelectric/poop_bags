defmodule PoopBags.DiffTest do
  use PoopBags.DataCase, async: false

  alias PoopBags.Catalog
  alias PoopBags.Diff

  # create_scan validates that the directory exists
  @subject_dir "/tmp/poop_bags_diff_subject"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(PoopBags.Repo, {:shared, self()})
    File.mkdir_p!(@subject_dir)
    on_exit(fn -> File.rm_rf!(@subject_dir) end)

    {:ok, baseline} =
      Catalog.create_scan(%{
        "project_path" => @subject_dir,
        "label" => "baseline",
        "threshold" => 20.0
      })

    {:ok, current} =
      Catalog.create_scan(%{
        "project_path" => @subject_dir,
        "label" => "current",
        "threshold" => 20.0
      })

    %{baseline: finish_scan!(baseline), current: current}
  end

  test "matched, improved, regressed, introduced, removed, resolved", %{
    baseline: baseline,
    current: current
  } do
    put_findings(baseline, [
      f("same_fn", 10.0, 3),
      # will improve: 10 → 6
      f("refactored_fn", 10.0, 3),
      # will regress: 10 → 30 (still violation)
      f("rotting_fn", 10.0, 3),
      # will resolve: 30 → 6 (violation → clean)
      f("rescued_fn", 30.0, 5),
      # will disappear
      f("deleted_fn", 10.0, 3)
    ])

    put_findings(current, [
      f("same_fn", 10.0, 3),
      f("refactored_fn", 6.0, 2),
      f("rotting_fn", 30.0, 5),
      f("rescued_fn", 6.0, 2),
      f("brand_new_fn", 42.0, 6)
    ])

    current = finish_scan!(current)
    diff = Diff.between(baseline, current)

    assert diff.comparable
    by_name = rows_by_outcome(diff)

    assert by_name[:unchanged] == ~w(same_fn)
    assert by_name[:improved] == ~w(refactored_fn)
    assert by_name[:regressed] == ~w(rotting_fn)
    assert by_name[:resolved] == ~w(rescued_fn)
    assert by_name[:introduced] == ~w(brand_new_fn)
    assert by_name[:removed] == ~w(deleted_fn)

    summary = diff.summary
    assert summary.unchanged == 1
    assert summary.improved == 1
    assert summary.regressed == 1
    assert summary.resolved == 1
    assert summary.introduced == 1
    assert summary.removed == 1

    # gate: introduced violations + regressions
    failing = Diff.gate_failures(diff) |> Enum.map(&identity_name/1)
    assert failing == ~w(brand_new_fn rotting_fn)
    refute Diff.gate_passed?(diff)
  end

  test "the gate passes when only things got better", %{baseline: baseline, current: current} do
    put_findings(baseline, [f("old_violation", 99.0, 9)])
    put_findings(current, [f("old_violation", 6.0, 2)])
    current = finish_scan!(current)

    diff = Diff.between(baseline, current)
    assert diff.summary.resolved == 1
    assert Diff.gate_passed?(diff)
  end

  test "clause suffixes are presentation: multi-clause functions match", %{
    baseline: baseline,
    current: current
  } do
    put_findings(baseline, [
      %{f("f/1", 12.0, 3) | function_name: "f/1"},
      %{f("f/1", 8.0, 2) | function_name: "f/1 (clause 2)"}
    ])

    put_findings(current, [
      # worst clause now lower
      %{f("f/1", 6.0, 2) | function_name: "f/1"}
    ])

    finish_scan!(current)
    diff = Diff.between(baseline, current)

    assert diff.summary.improved == 1
    assert diff.summary.introduced == 0
  end

  test "mismatched policies and projects warn and mark incomparable", %{
    baseline: baseline,
    current: current
  } do
    put_findings(baseline, [f("a", 10.0, 3)])
    put_findings(current, [f("a", 10.0, 3)])
    finish_scan!(current)

    current
    |> Ecto.Changeset.change(stats: %{"policy" => "some-future-policy-v2"})
    |> PoopBags.Repo.update!()

    diff = Diff.between(baseline, PoopBags.Catalog.get_scan!(current.id))
    refute diff.comparable
    assert diff.warnings |> Enum.join(" ") =~ "policies differ"

    other =
      baseline
      |> Ecto.Changeset.change(project_path: "/tmp/other_project")
      |> PoopBags.Repo.update!()

    diff2 = Diff.between(other, current)
    refute diff2.comparable
    assert diff2.warnings |> Enum.join(" ") =~ "different projects"
  end

  # ---------------------------------------------------------------- helpers

  defp f(name, crap, cx) do
    %{
      language: "zig",
      path: "src/tool.zig",
      module_name: "Tool",
      function_name: name,
      line: 1,
      end_line: 10,
      complexity: cx,
      crap: crap,
      coverage: 0.0,
      coverage_source: "assumed"
    }
  end

  defp put_findings(scan, rows) do
    now = DateTime.utc_now()

    rows =
      Enum.map(rows, fn row ->
        row
        |> Map.put(:scan_id, scan.id)
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    PoopBags.Repo.insert_all(PoopBags.Catalog.Finding, rows)
  end

  defp finish_scan!(scan) do
    scan
    |> Ecto.Changeset.change(
      status: "done",
      stats: %{
        "policy" =>
          "crap=comp^2*(1-cov)^3+comp; complexity=v1 (elixir-ast, zig/kotlin/swift-tokens)"
      },
      threshold: 20.0,
      finished_at: DateTime.utc_now()
    )
    |> PoopBags.Repo.update!()
  end

  defp rows_by_outcome(diff) do
    Enum.group_by(diff.rows, & &1.outcome, &identity_name/1)
  end

  defp identity_name(row) do
    {_lang, _path, _module, name} = row.identity
    name
  end
end
