defmodule PoopBagsWeb.Router do
  use PoopBagsWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PoopBagsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", PoopBagsWeb do
    pipe_through :browser

    get "/", PageController, :home
    post "/scans", ScanController, :create
    get "/scans/:id", ScanController, :show
    get "/scans/:id/trends", ScanController, :trends
    get "/scans/:id/diff", ScanController, :diff
    get "/scans/:id/explain", ScanController, :explain
    post "/scans/:id/delete", ScanController, :delete
    post "/scans/:id/pin", ScanController, :pin
  end

  scope "/api", PoopBagsWeb.API do
    pipe_through :api

    get "/", ScanController, :discover
    post "/scans", ScanController, :create
    get "/scans/:id", ScanController, :show
    get "/scans/:id/findings", ScanController, :findings
    get "/scans/:id/diff", ScanController, :diff
  end
end
