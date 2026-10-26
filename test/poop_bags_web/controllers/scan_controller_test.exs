defmodule PoopBagsWeb.ScanControllerTest do
  use PoopBagsWeb.ConnCase

  alias PoopBags.Catalog

  @fixture Path.join([File.cwd!(), "priv", "fixtures", "subject_project"])

  describe "POST /scans (html)" do
    test "with a bad path it flashes and redirects home", %{conn: conn} do
      conn = post(conn, ~p"/scans", %{"scan" => %{"project_path" => "/no/such/dir/anywhere"}})
      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not an existing directory"
    end

    test "with a fixture path it starts a scan and redirects to it", %{conn: conn} do
      conn =
        post(conn, ~p"/scans", %{"scan" => %{"project_path" => @fixture, "label" => "web run"}})

      assert redirected_to(conn) =~ ~r{/scans/\d+}
    end
  end

  describe "GET /scans/:id (html)" do
    test "renders findings of a finished scan", %{conn: conn} do
      scan = seeded_scan!()
      conn = get(conn, ~p"/scans/#{scan.id}")
      body = html_response(conn, 200)
      assert body =~ "Specimens"
      assert body =~ "beast"
      assert body =~ "biohazard"
    end

    test "renders the directory hotspots card", %{conn: conn} do
      scan = seeded_scan!()
      conn = get(conn, ~p"/scans/#{scan.id}")
      body = html_response(conn, 200)
      assert body =~ "Directory hotspots"
      assert body =~ "src"
      assert body =~ "112.0"
      assert body =~ "CRAP-excess"
    end

    test "language filter narrows the table", %{conn: conn} do
      scan = seeded_scan!()
      conn = get(conn, ~p"/scans/#{scan.id}?language=kotlin")
      body = html_response(conn, 200)
      assert body =~ "greet"
      refute body =~ "beast"
    end
  end

  describe "GET /scans/:id/trends" do
    test "renders the timeline and hotspot trend matrix", %{conn: conn} do
      scan = seeded_scan!()
      conn = get(conn, ~p"/scans/#{scan.id}/trends")
      body = html_response(conn, 200)

      assert body =~ "Scan timeline"
      assert body =~ "Hotspot trend"
      assert body =~ "(direct files)"
      assert body =~ Integer.to_string(scan.id)
    end

    test "marks threshold changes as boundaries, not regressions", %{conn: conn} do
      seeded_scan!()
      second = seeded_scan!(%{"threshold" => 45.0})

      conn = get(conn, ~p"/scans/#{second.id}/trends")
      body = html_response(conn, 200)

      assert body =~ "threshold 20.0→45.0"
      assert body =~ "not a regression"
    end
  end

  describe "POST /scans/:id/pin" do
    test "toggles the pin and reports retention protection", %{conn: conn} do
      scan = seeded_scan!()

      conn = post(conn, ~p"/scans/#{scan.id}/pin")
      assert redirected_to(conn) == ~p"/scans/#{scan.id}"
      assert Catalog.get_scan!(scan.id).pinned

      conn = post(conn, ~p"/scans/#{scan.id}/pin")
      assert redirected_to(conn) == ~p"/scans/#{scan.id}"
      refute Catalog.get_scan!(scan.id).pinned
    end
  end

  describe "API" do
    test "POST /api/scans accepts and reports", %{conn: conn} do
      conn =
        post(conn, ~p"/api/scans", %{
          "project_path" => @fixture,
          "coverage" => 50
        })

      assert %{"id" => id, "status" => "running"} = json_response(conn, 202)

      scan = await_done(id)
      assert scan.status == "done"
      assert scan.assumed_coverage == 0.5
    end

    test "POST /api/scans rejects a bad path", %{conn: conn} do
      conn = post(conn, ~p"/api/scans", %{"project_path" => "/definitely/not/here"})
      assert json_response(conn, 422)
    end

    test "GET /api/scans/:id/findings returns ranked json", %{conn: conn} do
      scan = seeded_scan!()
      conn = get(conn, ~p"/api/scans/#{scan.id}/findings")
      %{"findings" => findings} = json_response(conn, 200)
      assert length(findings) >= 4

      craps = Enum.map(findings, & &1["crap"])
      assert craps == Enum.sort(craps, &>=/2)
    end

    test "GET /api/scans/:id/findings reports 410 after retention expiry", %{conn: conn} do
      scan = seeded_scan!()
      expire!(scan)

      conn = get(conn, ~p"/api/scans/#{scan.id}/findings")
      assert %{"error" => err} = json_response(conn, 410)
      assert err =~ "expired"
    end

    test "GET /api/scans/:id/diff survives removed rows without crashing", %{conn: conn} do
      baseline = fabricated_scan!([{"gone", 30.0}, {"kept", 2.0}])
      current = fabricated_scan!([{"kept", 2.0}])

      conn = get(conn, ~p"/api/scans/#{current.id}/diff?against=#{baseline.id}")
      %{"rows" => rows} = json_response(conn, 200)

      removed = Enum.find(rows, &(&1["outcome"] == "removed"))
      assert removed["baseline_crap"] == 30.0
      assert removed["current_crap"] == nil
      assert removed["coverage"] == nil
    end
  end

  describe "retention guards (html)" do
    test "diff against an expired baseline redirects to trends with a flash", %{conn: conn} do
      baseline = seeded_scan!()
      current = seeded_scan!()
      expire!(baseline)

      conn = get(conn, ~p"/scans/#{current.id}/diff?against=#{baseline.id}")

      assert redirected_to(conn) == ~p"/scans/#{current.id}/trends"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "expired"
    end

    test "diff against a never-finished scan says unavailable, not all-introduced", %{conn: conn} do
      current = seeded_scan!()
      {:ok, doomed} = Catalog.create_scan(%{"project_path" => @fixture})

      conn = get(conn, ~p"/scans/#{current.id}/diff?against=#{doomed.id}")

      assert redirected_to(conn) == ~p"/scans/#{current.id}/trends"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "hasn't finished"
    end

    test "?against=<garbage> behaves like no baseline instead of crashing", %{conn: conn} do
      scan = seeded_scan!()

      conn = get(conn, ~p"/scans/#{scan.id}/diff?against=not-a-number")

      assert redirected_to(conn) == ~p"/scans/#{scan.id}"
    end

    test "an expired scan shows the expiry notice instead of findings", %{conn: conn} do
      scan = seeded_scan!()
      expire!(scan)

      conn = get(conn, ~p"/scans/#{scan.id}")
      body = html_response(conn, 200)

      assert body =~ "expired by retention"
      refute body =~ "beast"
      refute body =~ "No findings — either nothing stinks"
    end
  end

  defp seeded_scan!(extra \\ %{}) do
    attrs = Map.merge(%{"project_path" => @fixture, "label" => "seeded"}, extra)
    {:ok, scan} = Catalog.create_scan(attrs)
    Ecto.Adapters.SQL.Sandbox.mode(PoopBags.Repo, {:shared, self()})
    assert :ok = PoopBags.ScanSupervisor.start_scan(scan.id)
    await_done(scan.id)
  end

  defp expire!(scan) do
    scan
    |> Ecto.Changeset.change(details_expired_at: DateTime.utc_now())
    |> PoopBags.Repo.update!()
  end

  # A done scan with fabricated findings, no runner needed — for exercising
  # diff/guard paths directly.
  defp fabricated_scan!(findings) do
    {:ok, scan} = Catalog.create_scan(%{"project_path" => @fixture, "label" => "fabricated"})
    scan = Catalog.mark_running(scan, %{files_total: 1, config: %{}, threshold: 20.0})

    rows =
      Enum.map(findings, fn {name, crap} ->
        %{
          language: "zig",
          path: "src/a.zig",
          module_name: "",
          function_name: name,
          line: 1,
          end_line: 2,
          complexity: 2,
          crap: crap,
          coverage: 0.0,
          coverage_source: "assumed"
        }
      end)

    {:ok, _} =
      Catalog.commit_results(scan, rows, [], %{
        files_done: 1,
        files_failed: 0,
        files_skipped: 0,
        functions_total: length(rows),
        worst_crap: 2.0,
        avg_crap: 2.0,
        stats: %{"policy" => "p"},
        directories: []
      })

    Catalog.get_scan!(scan.id)
  end

  defp await_done(id, attempts \\ 100) do
    scan = Catalog.get_scan!(id)

    cond do
      scan.status in ~w(done error) -> scan
      attempts == 0 -> flunk("scan never finished: #{scan.status} #{scan.error}")
      true -> Process.sleep(50) && await_done(id, attempts - 1)
    end
  end
end
