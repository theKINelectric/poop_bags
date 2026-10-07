defmodule PoopBags.RetentionTest do
  use PoopBags.DataCase, async: true

  import Ecto.Query
  alias PoopBags.Catalog
  alias PoopBags.Catalog.Scan
  alias PoopBags.Catalog.ScanFile
  alias PoopBags.Repo
  alias PoopBags.Retention

  setup do
    dir = Path.join(System.tmp_dir!(), "pb_retention_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp commit_scan!(dir, tag) do
    {:ok, scan} = Catalog.create_scan(%{"project_path" => dir, "label" => "r#{tag}"})
    scan = Catalog.mark_running(scan, %{files_total: 1, config: %{}, threshold: 20.0})

    findings = [
      %{
        language: "zig",
        path: "src/a.zig",
        module_name: "",
        function_name: "f#{tag}",
        line: 1,
        end_line: 2,
        complexity: 2,
        crap: 2.0,
        coverage: 0.0,
        coverage_source: "assumed"
      }
    ]

    manifest = [%{path: "src/a.zig", size: 10, hash: "hash-#{tag}"}]

    directories = [
      %{
        path: "src",
        depth: 1,
        files: 1,
        functions: 1,
        violations: 0,
        worst_crap: 2.0,
        crap_excess: 0.0,
        measured_functions: 0,
        assumed_functions: 1
      }
    ]

    {:ok, _} =
      Catalog.commit_results(scan, findings, manifest, %{
        files_done: 1,
        files_failed: 0,
        files_skipped: 0,
        functions_total: 1,
        worst_crap: 2.0,
        avg_crap: 2.0,
        stats: %{"policy" => "p", "violations" => 0},
        directories: directories
      })

    Catalog.get_scan!(scan.id)
  end

  defp findings_count(scan) do
    Repo.aggregate(from(f in PoopBags.Catalog.Finding, where: f.scan_id == ^scan.id), :count)
  end

  defp manifest_count(scan) do
    Repo.aggregate(from(m in ScanFile, where: m.scan_id == ^scan.id), :count)
  end

  test "keeps the newest K done scans, expires older details but not summaries", %{dir: dir} do
    scans = Enum.map(1..4, &commit_scan!(dir, &1))
    [old | _rest] = scans
    newest = List.last(scans)

    :ok = Retention.sweep(dir)

    assert Retention.keep_count() == 3

    # the three newest keep findings
    for scan <- Enum.drop(scans, 1) do
      assert Scan.details_available?(scan)
      assert findings_count(scan) == 1
    end

    # the oldest: findings gone, marker set, but summary + aggregates + manifest survive
    old = Catalog.get_scan!(old.id)
    refute Scan.details_available?(old)
    assert old.details_expired_at != nil
    assert old.status == "done"
    assert old.functions_total == 1
    assert findings_count(old) == 0
    assert manifest_count(old) == 1
    assert Enum.map(Catalog.directory_rows(old, 1), & &1.path) == ["src"]

    # sweep is idempotent
    :ok = Retention.sweep(dir)
    newest = Catalog.get_scan!(newest.id)
    assert Scan.details_available?(newest)
    assert findings_count(Catalog.get_scan!(old.id)) == 0
  end

  test "pinned scans keep their details regardless of age", %{dir: dir} do
    first = commit_scan!(dir, :first)
    Catalog.toggle_pin(first)

    Enum.each(2..5, &commit_scan!(dir, &1))

    :ok = Retention.sweep(dir)

    first = Catalog.get_scan!(first.id)
    assert first.pinned
    assert Scan.details_available?(first)
    assert findings_count(first) == 1

    # the newest unpinned three are scans 5, 4, 3 — scan 2 expires instead
    expired = Repo.all(from(s in Scan, where: not is_nil(s.details_expired_at)))
    assert length(expired) == 1
    refute hd(expired).pinned
  end

  test "error scans never displace done history", %{dir: dir} do
    first = commit_scan!(dir, :first)

    {:ok, doomed} = Catalog.create_scan(%{"project_path" => dir, "label" => "doomed"})
    Catalog.fail_scan(doomed, "belt jam")

    Enum.each(2..4, &commit_scan!(dir, &1))

    :ok = Retention.sweep(dir)

    # four DONE scans exist: the newest three survive, the oldest expires —
    # the error row took no slot
    first = Catalog.get_scan!(first.id)
    refute Scan.details_available?(first)
  end

  test "sweep/0 covers every project", %{dir: dir} do
    other = Path.join(System.tmp_dir!(), "pb_retention_#{System.unique_integer([:positive])}")
    File.mkdir_p!(other)
    on_exit(fn -> File.rm_rf!(other) end)

    Enum.each(1..4, &commit_scan!(dir, &1))
    Enum.each(1..4, &commit_scan!(other, &1))

    :ok = Retention.sweep()

    assert Repo.aggregate(from(s in Scan, where: not is_nil(s.details_expired_at)), :count) == 2
  end
end
