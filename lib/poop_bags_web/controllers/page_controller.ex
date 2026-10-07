defmodule PoopBagsWeb.PageController do
  use PoopBagsWeb, :controller

  alias PoopBags.Catalog

  def home(conn, _params) do
    render(conn, :home, scans: Catalog.list_scans(20))
  end
end
