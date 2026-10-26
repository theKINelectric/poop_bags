defmodule PoopBags.ScanRunner do
  @moduledoc """
  One scan, one process — for the web.

  A single-purpose GenServer under `PoopBags.ScanSupervisor` that hands the
  scan to `PoopBags.Engine` (which walks, ingests coverage, drives the
  FlowExtra pipeline, and commits results) and always finishes the scan row
  — success or `error` with a reason — before stopping itself.
  """

  use GenServer

  alias PoopBags.Catalog
  alias PoopBags.Catalog.Scan
  alias PoopBags.Engine
  alias PoopBags.Repo

  def start_link(scan_id) do
    GenServer.start_link(__MODULE__, scan_id)
  end

  # :temporary — never restart. A crash or a mid-run delete must not re-run
  # the scan (duplicate findings) or, worse, crash-loop against a deleted
  # row until the DynamicSupervisor gives up and takes the app down.
  def child_spec(scan_id) do
    %{
      id: {__MODULE__, scan_id},
      start: {__MODULE__, :start_link, [scan_id]},
      restart: :temporary
    }
  end

  @impl true
  def init(scan_id) do
    send(self(), :run)
    {:ok, %{scan_id: scan_id}}
  end

  @impl true
  def handle_info(:run, state) do
    try do
      # The row may be gone before the run even starts; that is a stop, not
      # an error.
      case Repo.get(Scan, state.scan_id) do
        nil ->
          :ok

        scan ->
          case Engine.run(scan) do
            {:ok, _scan} -> :ok
            {:error, _reason} -> :ok
          end
      end
    rescue
      e ->
        # Engine already marked the row where it could; this covers the rest
        # (and tolerates a row deleted mid-run).
        Catalog.fail_scan_soft(state.scan_id, Exception.format(:error, e, __STACKTRACE__))
    end

    {:stop, :normal, state}
  end

  # Stray mailbox traffic (late monitors, FlowExtra replies) must not kill
  # the runner mid-scan.
  def handle_info(_other, state), do: {:noreply, state}
end
