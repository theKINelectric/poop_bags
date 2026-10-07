defmodule PoopBags.ScanIntegrationTest do
  use PoopBags.DataCase, async: false

  import Ecto.Query
  alias PoopBags.Catalog
  alias PoopBags.Repo
  alias PoopBags.ScanSupervisor

  @fixture Path.expand("../../priv/fixtures/subject_project", __DIR__)

  setup do
    # The runner runs in its own processes; share this test's sandbox
    # connection with everything it spawns.
    Ecto.Adapters.SQL.Sandbox.mode(PoopBags.Repo, {:shared, self()})

    assert File.dir?(@fixture), "missing fixture at #{@fixture}"
    :ok
  end

  test "a full scan over the fixture: runner, pipeline, persistence" do
    {:ok, scan} =
      Catalog.create_scan(%{"project_path" => @fixture, "label" => "fixture run"})

    assert :ok = ScanSupervisor.start_scan(scan.id)

    scan = await_done!(scan.id)

    assert scan.status == "done"
    assert scan.files_total == 4
    assert scan.files_done == 4
    assert scan.files_failed == 0

    findings = Catalog.top_findings(scan, limit: 100)
    assert length(findings) >= 4

    by_language = findings |> Enum.group_by(& &1.language)
    assert Map.has_key?(by_language, "elixir")
    assert Map.has_key?(by_language, "zig")
    assert Map.has_key?(by_language, "kotlin")
    assert Map.has_key?(by_language, "swift")

    # ranked worst-first
    craps = Enum.map(findings, & &1.crap)
    assert craps == Enum.sort(craps, &>=/2)

    # the worst specimen is the deeply branched zig function
    worst = hd(findings)
    assert worst.language == "zig"
    assert worst.function_name == "beast"
    assert worst.crap == 132.0

    # per-language stats present and policy stamped
    assert scan.stats["zig"]["functions"] >= 1
    assert scan.stats["policy"] =~ "comp^2"

    # avg/worst consistent with findings
    assert scan.worst_crap == 132.0
  end

  test "a full scan persists directory aggregates, violations, and timings" do
    {:ok, scan} =
      Catalog.create_scan(%{"project_path" => @fixture, "label" => "hotspots run"})

    assert :ok = ScanSupervisor.start_scan(scan.id)
    scan = await_done!(scan.id)

    assert scan.status == "done"

    # violation count is part of the summary (survives detail expiry)
    assert scan.stats["violations"] == 1
    assert is_integer(scan.stats["timings"]["belt_ms"])
    assert is_integer(scan.stats["timings"]["commit_ms"])

    # junk dirs never aggregate; every fixture dir does (no root files)
    depth1 = Catalog.directory_rows(scan, 1) |> Map.new(&{&1.path, &1})
    assert Map.keys(depth1) |> Enum.sort() == ~w(app ios lib src)

    src = depth1["src"]
    assert src.files == 1
    assert src.functions == 2
    assert src.violations == 1
    assert src.worst_crap == 132.0
    assert src.crap_excess == 112.0

    # default depth 2 stores the direct-files buckets too
    depth2 = Catalog.directory_rows(scan, 2) |> Map.new(&{&1.path, &1})
    assert depth2["src/(direct files)"].violations == 1
    assert Catalog.max_directory_depth(scan) == 2
  end

  @tag :tmp_dir
  test "a caller-task exit keeps the manifest honest and the scan alive", %{tmp_dir: tmp_dir} do
    project = Path.join(tmp_dir, "project")
    File.mkdir_p!(Path.join(project, "src"))
    File.write!(Path.join(project, "src/a.zig"), "fn calm() void {}\n")

    {:ok, scan} = Catalog.create_scan(%{"project_path" => project, "label" => "timeout run"})

    # A 1ms per-file timeout makes every pipeline call exit in its caller
    # task — the {:exit, _} belt path, end to end.
    assert {:ok, scan} = PoopBags.Engine.run(scan, per_file_timeout: 1, caller_pool: 2)

    assert scan.status == "done"
    assert scan.files_failed == 1
    assert scan.functions_total == 0

    # The lost file still lands in the manifest (hash unknown), the commit
    # survives the NOT NULL constraint, and no findings were invented.
    manifest =
      PoopBags.Repo.all(from(m in PoopBags.Catalog.ScanFile, where: m.scan_id == ^scan.id))

    assert [%{path: "src/a.zig", hash: "unknown"}] = manifest

    findings =
      Repo.aggregate(from(f in PoopBags.Catalog.Finding, where: f.scan_id == ^scan.id), :count)

    assert findings == 0
  end

  test "deleting a scan removes its findings" do
    {:ok, scan} = Catalog.create_scan(%{"project_path" => @fixture})
    assert :ok = ScanSupervisor.start_scan(scan.id)
    scan = await_done!(scan.id)
    assert scan.status == "done"

    findings = Catalog.top_findings(scan, limit: 500)
    assert findings != []

    {:ok, _} = Catalog.delete_scan(scan)
    assert Catalog.top_findings(%{scan | id: scan.id}, limit: 500) == []
  end

  defp await_done!(id, attempts \\ 100) do
    scan = Catalog.get_scan!(id)

    cond do
      scan.status in ~w(done error) -> scan
      attempts == 0 -> flunk("scan #{id} never finished (last status: #{scan.status})")
      true -> Process.sleep(50) && await_done!(id, attempts - 1)
    end
  end
end
