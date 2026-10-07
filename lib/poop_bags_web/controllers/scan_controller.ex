defmodule PoopBagsWeb.ScanController do
  use PoopBagsWeb, :controller

  alias PoopBags.Catalog
  alias PoopBags.Crap
  alias PoopBags.Diff
  alias PoopBags.ScanSupervisor

  def create(conn, %{"scan" => scan_params}) do
    attrs = %{
      "project_path" => scan_params["project_path"],
      "label" => scan_params["label"],
      "assumed_coverage" => coverage_ratio(scan_params["coverage"]),
      "threshold" => parse_optional_float(scan_params["threshold"])
    }

    case Catalog.create_scan(attrs) do
      {:ok, scan} ->
        case ScanSupervisor.start_scan(scan.id) do
          :ok ->
            redirect(conn, to: ~p"/scans/#{scan.id}")

          {:error, :busy} ->
            Catalog.fail_scan(scan, "scan belts are busy — too many scans already running")

            conn
            |> put_flash(:error, "Too many scans already running. Try again in a moment.")
            |> redirect(to: ~p"/")

          {:error, reason} ->
            Catalog.fail_scan(scan, "could not start scan runner: #{inspect(reason)}")

            conn
            |> put_flash(:error, "Could not start the scan runner.")
            |> redirect(to: ~p"/")
        end

      {:error, changeset} ->
        conn
        |> put_flash(:error, error_message(changeset))
        |> redirect(to: ~p"/")
    end
  end

  def show(conn, %{"id" => id}) do
    scan = Catalog.get_scan!(id)

    conn
    |> assign(:scan, scan)
    |> assign(:band, &Crap.band/1)
    |> assign(:band_label, &Crap.band_label/1)
    |> render(:show,
      findings: findings_for(scan, conn.params),
      languages: Catalog.languages_present(scan),
      history: Catalog.scan_history(scan),
      hotspots: Catalog.directory_rows(scan, hotspot_depth(scan, conn.params)),
      hotspot_depth: hotspot_depth(scan, conn.params),
      hotspot_depths: hotspot_depths(scan)
    )
  end

  def trends(conn, %{"id" => id} = params) do
    scan = Catalog.get_scan!(id)

    scans =
      scan.project_path
      |> Catalog.project_scans(8)
      |> Enum.reverse()

    newest = List.last(scans)
    # Depth follows the newest scan's aggregates — the matrix is anchored
    # there, and an old scan shouldn't default to a depth it never stored.
    depth = parse_depth(params["depth"]) || Catalog.max_directory_depth(newest || scan) || 2

    {matrix, max_excess} = hotspot_matrix(scans, depth)

    conn
    |> assign(:scan, scan)
    |> assign(:timeline, timeline(scans))
    |> assign(:matrix, matrix)
    |> assign(:scans, scans)
    |> assign(:depth, depth)
    |> assign(:hotspot_depths, hotspot_depths(newest || scan))
    |> assign(:max_excess, max_excess)
    |> render(:trends)
  end

  # The newest scan's rows decide which directories are shown; older scans
  # are queried for exactly those paths, so the page stays cheap however
  # many directories a project has.
  defp hotspot_matrix(scans, depth) do
    newest = List.last(scans)
    top_rows = (newest && Catalog.directory_rows(newest, depth) |> Enum.take(8)) || []
    paths = Enum.map(top_rows, & &1.path)

    rows_by_scan =
      Map.new(scans, fn s ->
        rows =
          if newest && s.id == newest.id,
            do: top_rows,
            else: Catalog.directory_rows(s, depth, paths)

        {s.id, rows}
      end)

    matrix =
      for dir <- top_rows do
        %{
          path: dir.path,
          cells:
            Enum.map(scans, fn s -> Enum.find(rows_by_scan[s.id], &(&1.path == dir.path)) end)
        }
      end

    max_excess =
      matrix
      |> Enum.flat_map(& &1.cells)
      |> Enum.map(&if &1, do: &1.crap_excess, else: 0.0)
      |> Enum.max(fn -> 0.0 end)

    {matrix, max_excess}
  end

  def pin(conn, %{"id" => id}) do
    scan = Catalog.get_scan!(id)

    if Catalog.Scan.running?(scan) do
      conn
      |> put_flash(:error, "Scan ##{scan.id} is still on the belts — wait for it to finish.")
      |> redirect(to: ~p"/scans/#{scan.id}")
    else
      scan = Catalog.toggle_pin(scan)

      message =
        cond do
          scan.pinned and not Catalog.Scan.details_available?(scan) ->
            "Scan ##{scan.id} pinned — but its details are already gone; pinning cannot resurrect them."

          scan.pinned ->
            "Scan ##{scan.id} pinned — retention will keep its details."

          true ->
            "Scan ##{scan.id} unpinned."
        end

      conn
      |> put_flash(:info, message)
      |> redirect(to: ~p"/scans/#{scan.id}")
    end
  end

  def diff(conn, %{"id" => id} = params) do
    scan = Catalog.get_scan!(id)

    cond do
      not Catalog.Scan.details_available?(scan) ->
        conn
        |> put_flash(
          :error,
          "Scan ##{scan.id} has no findings yet (#{scan.status}) or its details were expired " <>
            "by retention — its summary and hotspots remain on the trends page."
        )
        |> redirect(to: ~p"/scans/#{scan.id}/trends")

      true ->
        render_diff(conn, scan, PoopBagsWeb.Baseline.resolve(params, scan), params)
    end
  end

  defp render_diff(conn, scan, :none, _params) do
    conn
    |> put_flash(:info, "No earlier scan of this project to compare against yet.")
    |> redirect(to: ~p"/scans/#{scan.id}")
  end

  defp render_diff(conn, scan, {:unavailable, baseline}, _params) do
    reason =
      if baseline.status != "done",
        do: "hasn't finished (#{baseline.status}) and carries no findings",
        else: "'s details were expired by retention"

    conn
    |> put_flash(
      :error,
      "Baseline scan ##{baseline.id}#{reason} " <>
        "(the last #{PoopBags.Retention.keep_count()} done scans per project keep details; pin one to protect it)."
    )
    |> redirect(to: ~p"/scans/#{scan.id}/trends")
  end

  defp render_diff(conn, scan, {:ok, baseline}, params) do
    diff = Diff.between(baseline, scan, limit: parse_limit(Map.get(params, "limit")))

    rows =
      if params["outcome"] in diff_outcomes(),
        do: Enum.filter(diff.rows, &(&1.outcome == String.to_existing_atom(params["outcome"]))),
        else: diff.rows

    conn
    |> assign(:scan, scan)
    |> assign(:diff, diff)
    |> assign(:rows, rows)
    |> render(:diff)
  end

  def explain(conn, %{"id" => id} = params) do
    scan = Catalog.get_scan!(id)
    finding_id = params["finding"]

    case Catalog.get_scan(scan.id) &&
           Catalog.Scan.details_available?(scan) &&
           Enum.find(Catalog.all_findings(scan), &(&1.id == parse_int(finding_id))) do
      nil ->
        message =
          cond do
            scan.status != "done" ->
              "Scan ##{scan.id} hasn't finished (#{scan.status}) — explanations need function-level findings."

            not Catalog.Scan.details_available?(scan) ->
              "Scan ##{scan.id}'s details were expired by retention — explanations need function-level findings."

            true ->
              "That specimen is not in scan ##{scan.id}."
          end

        conn
        |> put_flash(:error, message)
        |> redirect(to: ~p"/scans/#{scan.id}")

      finding ->
        source = read_source(scan, finding)
        breakdown = breakdown_for(scan, finding, source)

        conn
        |> assign(:scan, scan)
        |> assign(:finding, finding)
        |> assign(:source_available?, source != nil)
        |> assign(:breakdown, breakdown)
        |> assign(:band, Crap.band(finding.crap))
        |> assign(:band_label, Crap.band_label(Crap.band(finding.crap)))
        |> render(:explain)
    end
  end

  def delete(conn, %{"id" => id}) do
    scan = Catalog.get_scan!(id)

    if Catalog.Scan.running?(scan) do
      conn
      |> put_flash(:error, "Scan ##{scan.id} is still on the belts — wait for it to finish.")
      |> redirect(to: ~p"/scans/#{scan.id}")
    else
      Catalog.delete_scan(scan)

      conn
      |> put_flash(:info, "Scan ##{scan.id} bagged and binned.")
      |> redirect(to: ~p"/")
    end
  end

  # ---------------------------------------------------------------- explain helpers

  defp read_source(scan, finding) do
    path = Path.join(scan.project_path, finding.path)
    if File.exists?(path), do: File.read(path)
  end

  defp breakdown_for(_scan, finding, {:ok, source}) do
    lang = String.to_existing_atom(finding.language)

    case lang do
      :elixir ->
        base = String.replace(finding.function_name, ~r/ \(clause \d+\)$/, "")
        PoopBags.ElixirAnalyzer.explain(source, base)

      _ ->
        PoopBags.TokenAnalyzer.explain(source, lang, finding.function_name)
    end
  end

  defp breakdown_for(_scan, _finding, _), do: :unavailable

  # ---------------------------------------------------------------- parsing helpers

  defp findings_for(scan, params) do
    Catalog.top_findings(scan,
      language: params["language"],
      limit: parse_limit(params["limit"])
    )
  end

  defp hotspot_depth(scan, params) do
    case parse_depth(params["depth"]) do
      nil -> Catalog.max_directory_depth(scan) || 2
      depth -> depth
    end
  end

  defp hotspot_depths(scan), do: 1..(Catalog.max_directory_depth(scan) || 2)

  defp parse_depth(nil), do: nil

  defp parse_depth(raw) do
    case Integer.parse(to_string(raw)) do
      {n, ""} when n >= 1 and n <= 4 -> n
      _ -> nil
    end
  end

  # The diff page's outcome filter is untrusted input — unknown values show
  # every row rather than crashing on to_existing_atom.
  defp diff_outcomes, do: ~w(introduced regressed improved resolved removed unchanged)

  # ---------------------------------------------------------------- trends helpers

  # One timeline entry per done scan (oldest first), each annotated with the
  # comparability boundaries against the scan before it: threshold, policy,
  # scope, or coverage-provenance changes are boundaries, not regressions.
  defp timeline(scans) do
    {rows, _} =
      Enum.map_reduce(scans, nil, fn scan, prev ->
        {%{scan: scan, boundaries: if(prev, do: boundaries(prev, scan), else: [])}, scan}
      end)

    rows
  end

  defp boundaries(old, new) do
    []
    |> maybe_boundary(old.threshold != new.threshold, fn ->
      "threshold #{fmt_num(old.threshold)}→#{fmt_num(new.threshold)}"
    end)
    |> maybe_boundary(policy(old) != policy(new), fn -> "scoring policy changed" end)
    |> maybe_boundary(scope(old) != scope(new), fn ->
      "scope changed (exclusions/languages/depth)"
    end)
    |> maybe_boundary(coverage_mode(old) != coverage_mode(new), fn ->
      "coverage provenance changed"
    end)
  end

  defp maybe_boundary(notes, true, note), do: notes ++ [note.()]
  defp maybe_boundary(notes, false, _note), do: notes

  defp policy(%{stats: %{"policy" => p}}), do: p
  defp policy(_), do: nil

  defp scope(%{config: config}),
    do: Map.take(config || %{}, ["exclude", "languages", "hotspot_depth"])

  defp coverage_mode(%{stats: %{"coverage" => %{"measured_functions" => m}}}), do: m > 0
  defp coverage_mode(_), do: false

  defp fmt_num(nil), do: "–"
  defp fmt_num(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 1)
  defp fmt_num(n), do: to_string(n)

  defp parse_limit(nil), do: 100

  defp parse_limit(raw) do
    case Integer.parse(to_string(raw)) do
      {n, _} -> n |> max(1) |> min(500)
      :error -> 100
    end
  end

  defp parse_int(nil), do: nil

  defp parse_int(raw) do
    case Integer.parse(to_string(raw)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp coverage_ratio(nil), do: 0.0

  defp coverage_ratio(raw) do
    case Float.parse(to_string(raw)) do
      {pct, _} -> pct |> max(0.0) |> min(100.0) |> then(&Float.round(&1 / 100.0, 4))
      :error -> 0.0
    end
  end

  defp parse_optional_float(nil), do: nil
  defp parse_optional_float(""), do: nil

  defp parse_optional_float(raw) do
    case Float.parse(to_string(raw)) do
      {v, _} -> v
      :error -> nil
    end
  end

  defp error_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {k, v} -> "#{k} #{v}" end)
  end
end
