defmodule PoopBags.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PoopBagsWeb.Telemetry,
      PoopBags.Repo,
      # Single-node SQLite: migrations are idempotent and fast, so they run
      # on every boot (releases included) unless SKIP_MIGRATIONS is set —
      # a fresh deploy brings its own schema up before serving.
      {Ecto.Migrator,
       repos: Application.fetch_env!(:poop_bags, :ecto_repos),
       skip: System.get_env("SKIP_MIGRATIONS") not in [nil, ""]},
      {DNSCluster, query: Application.get_env(:poop_bags, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: PoopBags.PubSub},
      {Task.Supervisor, name: PoopBags.CallerSupervisor},
      PoopBags.ScanSupervisor,
      # Reconcile stale scans (queued/running by a previous VM life) BEFORE
      # the endpoint starts accepting requests, so a fresh scan can never be
      # created into the reap window — then enforce detail retention.
      {Task,
       fn ->
         PoopBags.Catalog.reap_orphaned_scans!()
         PoopBags.Retention.sweep()
       end},
      # Start to serve requests, typically the last entry
      PoopBagsWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for more details on other strategies and information
    opts = [strategy: :one_for_one, name: PoopBags.Supervisor]

    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PoopBagsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
