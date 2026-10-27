defmodule PoopBagsWeb.JavaScriptProvenanceTrendsTest do
  use PoopBagsWeb.ConnCase, async: false
  alias PoopBags.{Catalog, Engine, Repo, Diff}

  @tag :tmp_dir
  test "parser-only version change marks the actual trends response as a policy boundary", %{
    conn: conn,
    tmp_dir: root
  } do
    File.write!(
      Path.join(root, "main.ts"),
      "export function eligible(age: number) { return age >= 18; }"
    )

    before = scan(root)
    current = scan(root)

    # Model a recorded scan made by a later parser version without executing an untrusted helper.
    parsers = Enum.map(current.stats["parsers"], &Map.put(&1, "parser_version", "7.29.10"))
    stats = Map.put(current.stats, "parsers", parsers)
    current = current |> Ecto.Changeset.change(stats: stats) |> Repo.update!()
    refute Diff.between(before, current).comparable

    body = conn |> get(~p"/scans/#{current.id}/trends") |> html_response(200)
    assert body =~ "scoring policy changed"
    assert body =~ "not a regression"
  end

  @tag :tmp_dir
  test "identical parser versions do not create a false trends boundary", %{
    conn: conn,
    tmp_dir: root
  } do
    File.write!(
      Path.join(root, "main.ts"),
      "export function eligible(age: number) { return age >= 18; }"
    )

    scan(root)
    current = scan(root)
    body = conn |> get(~p"/scans/#{current.id}/trends") |> html_response(200)
    refute body =~ "scoring policy changed"
  end

  defp scan(root) do
    {:ok, scan} = Catalog.create_scan(%{"project_path" => root})
    {:ok, scan} = Engine.run(scan)
    scan
  end
end
