defmodule PoopBagsWeb.JavaScriptMetadataTest do
  use PoopBagsWeb.ConnCase, async: false

  alias PoopBags.{Catalog, Engine, Repo}

  @tag :tmp_dir
  test "a real TypeScript scan renders metadata separately from language totals", %{
    conn: conn,
    tmp_dir: root
  } do
    scan = scan_with_metadata(root)
    assert [%{"parser" => "@babel/parser"}] = scan.stats["parsers"]
    assert Enum.map(PoopBagsWeb.ScanHTML.language_stats(scan), &elem(&1, 0)) == ["typescript"]

    response = conn |> get(~p"/scans/#{scan.id}") |> html_response(200)
    assert response =~ "eligible"
    assert response =~ "typescript"
    assert response =~ "Parser provenance"
    assert response =~ "@babel/parser"
    assert response =~ "7.29.9"
    assert response =~ "module_scope"
  end

  @tag :tmp_dir
  test "scan API exposes parsers and analyzer skips outside by_language", %{
    conn: conn,
    tmp_dir: root
  } do
    scan = scan_with_metadata(root)
    response = conn |> get(~p"/api/scans/#{scan.id}") |> json_response(200)
    assert Map.keys(response["by_language"]) == ["typescript"]
    assert response["parsers"] == scan.stats["parsers"]
    assert response["analyzer_skips"] == scan.stats["analyzer_skips"]
  end

  defp scan_with_metadata(root) do
    File.write!(
      Path.join(root, "main.ts"),
      "export function eligible(age: number) { return age >= 18; }"
    )

    {:ok, scan} = Catalog.create_scan(%{"project_path" => root})
    {:ok, scan} = Engine.run(scan)
    assert scan.files_failed == 0

    # Keep this presentation regression independent of analyzer skip generation.
    stats =
      Map.put(scan.stats, "analyzer_skips", [%{"path" => "main.ts", "reason" => "module_scope"}])

    scan |> Ecto.Changeset.change(stats: stats) |> Repo.update!()
  end
end
