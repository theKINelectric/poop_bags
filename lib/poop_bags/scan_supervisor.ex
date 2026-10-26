defmodule PoopBags.ScanSupervisor do
  @moduledoc """
  One `PoopBags.ScanRunner` child per live scan.
  """

  use DynamicSupervisor

  alias PoopBags.ScanRunner

  # Each scan is a FlowExtra pipeline (~15 stages) plus a 12-task caller
  # pool; a handful at a time is plenty for a local tool. Enforced by
  # max_children so the check and the start are one serialized decision.
  @max_concurrent_scans 3

  def start_link(_arg) do
    DynamicSupervisor.start_link(__MODULE__, :ok,
      name: __MODULE__,
      max_children: @max_concurrent_scans
    )
  end

  @doc """
  Spawns the runner for a freshly queued scan. Returns `{:error, :busy}` when
  too many scans are already on the belts.
  """
  def start_scan(scan_id) do
    case DynamicSupervisor.start_child(__MODULE__, {ScanRunner, scan_id}) do
      {:ok, _pid} -> :ok
      {:error, :max_children} -> {:error, :busy}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)
end
