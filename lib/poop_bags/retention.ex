defmodule PoopBags.Retention do
  @moduledoc """
  Count-based detail retention.

  A ~99k-finding scan accumulates fast, so only the latest K successful
  scans of each project keep their per-function findings; older ones keep
  the summary row, directory aggregates, and file manifest, and gain a
  `details_expired_at` marker. Pinned baselines are exempt — pinning is the
  explicit, narrow protection (viewing a diff never pins anything).

  Ordering is by completion time with scan ID as tie-breaker; failed or
  interrupted scans never displace successful history (they carry no
  findings anyway). Sweeps run after every successful commit and at boot —
  always outside the commit transaction, idempotent, and failure-tolerant:
  a sweep problem is logged, never propagated to the scan that triggered it.

  Configure the count at the application level (`config :poop_bags,
  :retention_keep`, default 3) — retention governs storage lifecycle for
  this installation, not what or how a project measures.
  """

  require Logger

  import Ecto.Query
  alias PoopBags.Catalog.Finding
  alias PoopBags.Catalog.Scan
  alias PoopBags.Repo

  @keep_default 3

  @doc "Sweeps every known project (boot path)."
  @spec sweep() :: :ok
  def sweep do
    from(s in Scan, select: s.project_path, distinct: true)
    |> Repo.all()
    |> Enum.each(&sweep/1)

    :ok
  rescue
    e ->
      Logger.warning("retention sweep failed: #{Exception.message(e)}")
      :ok
  end

  @doc "Expires detail findings beyond the keep count for one project."
  @spec sweep(String.t()) :: :ok
  def sweep(project_path) when is_binary(project_path) do
    # (SQLite demands LIMIT alongside OFFSET, and projects carry few scans —
    # fetch the done-and-unpinned queue and drop the newest `keep_count` in
    # Elixir instead.)
    candidates =
      from(s in Scan,
        where:
          s.project_path == ^project_path and s.status == "done" and
            not s.pinned and is_nil(s.details_expired_at),
        order_by: [desc: s.finished_at, desc: s.id],
        select: s.id
      )
      |> Repo.all()

    candidates
    |> Enum.drop(keep_count())
    |> Enum.each(&expire_scan/1)
  rescue
    e ->
      Logger.warning("retention sweep of #{project_path} failed: #{Exception.message(e)}")
      :ok
  end

  @doc "The configured keep count (>= 1)."
  @spec keep_count() :: pos_integer()
  def keep_count do
    Application.get_env(:poop_bags, :retention_keep, @keep_default)
    |> case do
      n when is_integer(n) and n >= 1 -> n
      _ -> @keep_default
    end
  end

  # Summary, directory aggregates, and manifest survive; findings go and the
  # expiry marker lands in the same transaction. The marker update is
  # conditional (unpinned, not yet expired), so a pin that lands between the
  # candidate query and here wins the race: a pinned scan keeps its findings
  # and its badge stays honest.
  defp expire_scan(scan_id) do
    now = DateTime.utc_now()

    result =
      Repo.transaction(fn ->
        {claimed, _} =
          Repo.update_all(
            from(s in Scan,
              where: s.id == ^scan_id and not s.pinned and is_nil(s.details_expired_at),
              select: s.id
            ),
            set: [details_expired_at: now, updated_at: now]
          )

        if claimed == 1,
          do: Repo.delete_all(from(f in Finding, where: f.scan_id == ^scan_id)),
          else: :lost_race

        claimed
      end)

    case result do
      {:ok, 1} ->
        Logger.info("retention: expired details of scan ##{scan_id}")

      {:ok, 0} ->
        Logger.info("retention: scan ##{scan_id} was pinned or already expired — kept")

      {:error, reason} ->
        Logger.warning("retention: could not expire scan ##{scan_id}: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.warning("retention: could not expire scan ##{scan_id}: #{Exception.message(e)}")
  end
end
