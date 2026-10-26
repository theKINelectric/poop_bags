defmodule PoopBagsWeb.PageControllerTest do
  use PoopBagsWeb.ConnCase

  test "GET / shows the bagging form and recent scans", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    assert body =~ "poop_bags"
    assert body =~ "Project directory"
    assert body =~ "Bag it"
    assert body =~ "Nothing bagged yet"
  end
end
