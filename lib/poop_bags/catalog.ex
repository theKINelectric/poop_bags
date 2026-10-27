defmodule PoopBags.Catalog do
  @moduledoc """
  The bagging ledger: scans, findings, and file manifests, persisted in
  SQLite.
  """

  import Ecto.Query
  alias PoopBags.Catalog.Finding
  alias PoopBags.Catalog.Scan
  alias PoopBags.Catalog.ScanDirectory
  alias PoopBags.Catalog.ScanFile
  alias PoopBags.Repo

  # ---------------------------------------------------------------- creation

  @doc "Creates a queued scan after checking the directory exists."
  def create_scan(attrs) do
    %Scan{}
    |> Scan.changeset(attrs)
    |> Repo.insert()
  end

  def get_scan!(id), do: Repo.get!(Scan, id)

  def get_scan(id), do: Repo.get(Scan, id)

  def list_scans(limit \\ 50) do
    from(s in Scan, order_by: [desc: s.inserted_at], limit: ^limit)
    |> Repo.all()
  end

  @doc "The most recent finished scan of the same project, if any."
  def latest_baseline(%Scan{} = scan) do
    from(s in Scan,
      where:
        s.project_path == ^scan.project_path and
          s.status == "done" and is_nil(s.details_expired_at) and
          s.id != ^scan.id,
      order_by: [desc: s.finished_at, desc: s.id],
      limit: 1
    )
    |> Repo.one()
  end

  @doc "Finished scans of the same project, newest first (baseline picker)."
  def scan_history(%Scan{} = scan, limit \\ 20) do
    from(s in Scan,
      where:
        s.project_path == ^scan.project_path and
          s.status == "done" and
          s.id != ^scan.id,
      order_by: [desc: s.finished_at, desc: s.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Done scans of a project by path, newest first, including `scan` itself —
  the trend timeline's raw material. Summaries survive detail expiry, so
  this keeps working for expired scans.
  """
  def project_scans(project_path, limit \\ 10) when is_binary(project_path) do
    from(s in Scan,
      where: s.project_path == ^project_path and s.status == "done",
      order_by: [desc: s.finished_at, desc: s.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Pins or unpins a baseline: pinned scans are exempt from detail retention.
  Pinning is the only protection — diffing against a scan pins nothing.
  """
  def toggle_pin(%Scan{} = scan) do
    scan
    |> Ecto.Changeset.change(pinned: not scan.pinned)
    |> Repo.update!()
  end

  def delete_scan(%Scan{} = scan), do: Repo.delete(scan)

  # ---------------------------------------------------------------- progress

  def mark_running(%Scan{} = scan, attrs) do
    files_total = Map.get(attrs, :files_total, 0)
    config = Map.get(attrs, :config, %{})

    scan
    |> Ecto.Changeset.change(
      status: "running",
      files_total: files_total,
      files_done: 0,
      config: config,
      config_digest: Map.get(config, "digest", "none"),
      threshold: Map.get(attrs, :threshold, scan.threshold || 20.0),
      started_at: DateTime.utc_now()
    )
    |> Repo.update!()
  end

  def report_progress(scan_id, files_done, files_failed) do
    Repo.update_all(
      from(s in Scan, where: s.id == ^scan_id),
      set: [files_done: files_done, files_failed: files_failed, updated_at: DateTime.utc_now()]
    )
  rescue
    # Progress is cosmetic; a busy database (another scan holding the single
    # writer) must not kill the runner over a dropped progress bump.
    _ -> :ok
  end

  @doc "Records a non-fatal coverage warning (web scans degrade, CI fails)."
  def note_coverage_warning(scan_id, reason) do
    case Repo.get(Scan, scan_id) do
      nil ->
        :ok

      scan ->
        scan
        |> Ecto.Changeset.change(stats: Map.put(scan.stats || %{}, "coverage_warning", reason))
        |> Repo.update!()

        :ok
    end
  end

  @doc """
  Records one stats key after the fact (e.g. commit timings, which can only
  be known once the commit finished). Best-effort: a lost timing never
  disturbs a finished scan.
  """
  def note_stat(scan_id, key, value) do
    case Repo.get(Scan, scan_id) do
      nil ->
        :ok

      scan ->
        scan
        |> Ecto.Changeset.change(stats: Map.put(scan.stats || %{}, key, value))
        |> Repo.update!()

        :ok
    end
  rescue
    _ -> :ok
  end

  def finish_scan(%Scan{} = scan, summary) do
    scan
    |> Ecto.Changeset.change(
      status: "done",
      files_done: summary.files_done,
      files_failed: summary.files_failed,
      files_skipped: summary.files_skipped,
      functions_total: summary.functions_total,
      worst_crap: summary.worst_crap,
      avg_crap: summary.avg_crap,
      stats: summary.stats,
      finished_at: DateTime.utc_now()
    )
    |> Repo.update!()
  end

  def fail_scan(%Scan{} = scan, reason) do
    scan
    |> Ecto.Changeset.change(
      status: "error",
      error: reason,
      finished_at: DateTime.utc_now()
    )
    |> Repo.update!()
  end

  @doc """
  Boots clean: any scan left `queued`/`running` by a previous VM life is
  marked errored, since nothing will ever resume it.
  """
  def reap_orphaned_scans! do
    Repo.update_all(
      from(s in Scan, where: s.status in ~w(queued running)),
      set: [
        status: "error",
        error: "interrupted by a server restart",
        finished_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      ]
    )

    :ok
  end

  @doc "fail_scan/2 for a scan row that may have been deleted mid-run."
  def fail_scan_soft(scan_id, reason) do
    case Repo.get(Scan, scan_id) do
      nil -> :ok
      scan -> fail_scan(scan, reason)
    end
  end

  @doc """
  All-or-nothing completion: findings, the file manifest, directory
  aggregates, and the finished summary land in one transaction, so a scan
  row is never left half-populated (or double-filled by a retry) — and the
  durable directory aggregates exist before retention can expire details.
  """
  def commit_results(%Scan{} = scan, findings, manifest, summary) do
    Repo.transaction(fn ->
      Repo.delete_all(from(f in Finding, where: f.scan_id == ^scan.id))
      Repo.delete_all(from(f in ScanFile, where: f.scan_id == ^scan.id))
      Repo.delete_all(from(d in ScanDirectory, where: d.scan_id == ^scan.id))
      insert_findings!(scan, findings)
      insert_manifest!(scan, manifest)
      insert_directories!(scan, Map.get(summary, :directories, []))
      finish_scan(scan, summary)
    end)
  end

  # ---------------------------------------------------------------- findings

  defp insert_findings!(%Scan{} = scan, rows) do
    now = DateTime.utc_now()

    rows
    |> Enum.chunk_every(1_000)
    |> Enum.each(fn chunk ->
      entries =
        Enum.map(chunk, fn row ->
          row
          |> Map.take([
            :language,
            :path,
            :module_name,
            :function_name,
            :line,
            :end_line,
            :complexity,
            :crap,
            :coverage,
            :coverage_source
          ])
          |> Map.merge(%{scan_id: scan.id, inserted_at: now, updated_at: now})
        end)

      Repo.insert_all(Finding, entries)
    end)
  end

  defp insert_manifest!(%Scan{} = scan, entries) do
    now = DateTime.utc_now()

    entries
    |> Enum.chunk_every(1_000)
    |> Enum.each(fn chunk ->
      rows =
        Enum.map(chunk, fn entry ->
          %{
            scan_id: scan.id,
            path: entry.path,
            size: entry.size,
            hash: entry.hash,
            inserted_at: now,
            updated_at: now
          }
        end)

      Repo.insert_all(ScanFile, rows)
    end)
  end

  defp insert_directories!(%Scan{} = scan, rows) do
    now = DateTime.utc_now()

    entries =
      Enum.map(rows, fn row ->
        row
        |> Map.take([
          :path,
          :depth,
          :files,
          :functions,
          :violations,
          :worst_crap,
          :crap_excess,
          :measured_functions,
          :assumed_functions
        ])
        |> Map.merge(%{scan_id: scan.id, inserted_at: now, updated_at: now})
      end)

    unless entries == [] do
      Repo.insert_all(ScanDirectory, entries)
    end
  end

  @doc "Worst-first findings for a scan, optionally narrowed to one language."
  def top_findings(%Scan{} = scan, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    min_crap = Keyword.get(opts, :min_crap, 1.0)
    language = Keyword.get(opts, :language)

    from(f in Finding,
      where: f.scan_id == ^scan.id and f.crap >= ^min_crap,
      order_by: [desc: f.crap, desc: f.complexity, asc: f.path],
      limit: ^limit
    )
    |> maybe_filter_language(language)
    |> Repo.all()
  end

  @doc "Every finding of a scan — the diff's raw material."
  def all_findings(%Scan{} = scan) do
    Repo.all(from(f in Finding, where: f.scan_id == ^scan.id))
  end

  defp maybe_filter_language(query, nil), do: query

  defp maybe_filter_language(query, language) when is_binary(language) do
    where(query, [f], f.language == ^language)
  end

  def languages_present(%Scan{} = scan) do
    from(f in Finding, where: f.scan_id == ^scan.id, select: f.language, distinct: true)
    |> Repo.all()
  end

  # ---------------------------------------------------------------- directories

  @doc """
  Directory aggregates for a scan, worst burden first. `depth` picks the
  display level (1 = first path segment, 2 = first two, ...); `nil` returns
  every stored level. `paths` restricts to named groups (the trends matrix
  fetches only the directories it will display). Rows live independently of
  findings, so hotspots survive detail expiry.
  """
  def directory_rows(%Scan{} = scan, depth \\ nil, paths \\ nil) do
    from(d in ScanDirectory, where: d.scan_id == ^scan.id, order_by: [desc: d.crap_excess])
    |> maybe_filter_depth(depth)
    |> maybe_filter_paths(paths)
    |> Repo.all()
  end

  defp maybe_filter_depth(query, nil), do: query

  defp maybe_filter_depth(query, depth) when is_integer(depth),
    do: where(query, [d], d.depth == ^depth)

  defp maybe_filter_paths(query, nil), do: query

  defp maybe_filter_paths(query, paths) when is_list(paths) and paths != [],
    do: where(query, [d], d.path in ^paths)

  defp maybe_filter_paths(query, _), do: query

  @doc "The deepest display level this scan stored aggregates for (or nil)."
  def max_directory_depth(%Scan{} = scan) do
    from(d in ScanDirectory, where: d.scan_id == ^scan.id, select: max(d.depth))
    |> Repo.one()
  end
end
