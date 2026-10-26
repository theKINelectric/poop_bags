defmodule PoopBagsWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :poop_bags

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_poop_bags_key",
    signing_salt: "L0PXe4Xq",
    same_site: "Lax"
  ]

  # socket "/live", Phoenix.LiveView.Socket,
  #   websocket: [connect_info: [session: @session_options]],
  #   longpoll: [connect_info: [session: @session_options]]

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  # The app generates URLs under an optional path prefix (PHX_URL_PATH,
  # e.g. /poopbags — the app's phi path-plane prefix), so its own links
  # survive being served behind the door. Routing must then accept both
  # shapes: the door strips the prefix before forwarding, but a link
  # followed on the loopback/name plane arrives WITH it. This plug
  # normalizes: an optional leading prefix moves into script_name (the
  # scoping behaviour Phoenix expects) and the pipeline proceeds at the
  # real path. With no prefix configured it does nothing. Sits before
  # Plug.Static so /<prefix>/assets/... strips to the real files too.
  plug :accept_url_path

  defp accept_url_path(conn, _opts) do
    prefix = Application.get_env(:poop_bags, :url_path, "") |> String.split("/", trim: true)

    case prefix do
      [] ->
        conn

      _ ->
        case Enum.split(conn.path_info, length(prefix)) do
          {^prefix, rest} ->
            %{conn | script_name: conn.script_name ++ prefix, path_info: rest}

          _ ->
            conn
        end
    end
  end

  plug Plug.Static,
    at: "/",
    from: :poop_bags,
    gzip: false,
    only: PoopBagsWeb.static_paths()

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :poop_bags
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug PoopBagsWeb.Router
end
