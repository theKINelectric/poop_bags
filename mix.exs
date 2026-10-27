defmodule PoopBags.MixProject do
  use Mix.Project

  def project do
    [
      app: :poop_bags,
      version: "0.1.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      # The agent face: the same JSON contract as the HTTP API over stdio.
      # The built artifact is committed at bin/poop_bags_mcp so agents can
      # run it straight from a checkout (needs only Erlang/Elixir on PATH).
      # app: false — the script talks HTTP; it must not boot the whole
      # supervision tree (the SQLite NIF cannot load from inside an escript).
      escript: [
        main_module: PoopBags.MCP,
        path: "bin/poop_bags_mcp",
        deps: [:jason],
        app: nil
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {PoopBags.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples.
  defp deps do
    [
      {:phoenix, "~> 1.7.20"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.10"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.0.0"},
      {:floki, ">= 0.30.0", only: :test},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:js_ts_parser, path: "../js_ts_parser/elixir"},
      {:dns_cluster, "~> 0.1.1"},
      {:bandit, "~> 1.5"},
      # The conveyor belt each bag rides: files in, CRAP findings out.
      # Sibling checkout wins when present (the house development layout);
      # cloners get the upstream repo.
      flowextra_dep()
    ]
  end

  defp flowextra_dep do
    if File.dir?(Path.expand("../flow_extra/lib")) do
      {:flowextra, path: "../flow_extra"}
    else
      {:flowextra, git: "https://codeberg.org/kin_electric/flow_extra.git"}
    end
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
