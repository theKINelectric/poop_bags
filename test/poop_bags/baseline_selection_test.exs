defmodule PoopBags.BaselineSelectionTest do
  use PoopBags.DataCase, async: false
  alias PoopBags.{Catalog, Repo}
  @tag :tmp_dir
  test "automatic baseline ignores expired details and chooses a usable scan", %{tmp_dir: root} do
    {:ok, available} = Catalog.create_scan(%{"project_path" => root})
    available = finish(available)
    {:ok, expired} = Catalog.create_scan(%{"project_path" => root})

    expired =
      finish(expired)
      |> Ecto.Changeset.change(details_expired_at: DateTime.utc_now())
      |> Repo.update!()

    {:ok, current} = Catalog.create_scan(%{"project_path" => root})
    assert Catalog.latest_baseline(current).id == available.id
    available |> Ecto.Changeset.change(details_expired_at: DateTime.utc_now()) |> Repo.update!()
    assert Catalog.latest_baseline(current) == nil
    assert expired.details_expired_at
  end

  defp finish(scan),
    do:
      scan
      |> Ecto.Changeset.change(status: "done", finished_at: DateTime.utc_now())
      |> Repo.update!()
end
