# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :poop_bags,
  ecto_repos: [PoopBags.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :poop_bags, PoopBagsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PoopBagsWeb.ErrorHTML, json: PoopBagsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: PoopBags.PubSub,
  live_view: [signing_salt: "gSswfo6g"]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# SQLite: WAL so the scan runner's writes and the web's reads don't lock horns.
config :poop_bags, PoopBags.Repo, default_options: [journal_mode: :wal, busy_timeout: 5_000]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
