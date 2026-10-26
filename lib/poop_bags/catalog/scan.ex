defmodule PoopBags.Catalog.Scan do
  @moduledoc """
  One bagging run over a project directory.

  Progress fields (`files_total`, `files_done`, ...) are updated live by the
  `PoopBags.ScanRunner` while the FlowExtra pipeline chews through files, so
  the show page can poll them.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(queued running done error)

  schema "scans" do
    field :project_path, :string
    field :label, :string
    field :status, :string, default: "queued"
    field :assumed_coverage, :float, default: 0.0
    field :files_total, :integer, default: 0
    field :files_done, :integer, default: 0
    field :files_failed, :integer, default: 0
    field :files_skipped, :integer, default: 0
    field :functions_total, :integer, default: 0
    field :worst_crap, :float, default: 0.0
    field :avg_crap, :float, default: 0.0
    # %{"zig" => %{"files" => 10, "functions" => 97, "crap_sum" => 1203.5}, ...}
    field :stats, :map, default: %{}
    # Effective project configuration (.poopbags.json merged with overrides)
    # and a digest of the file it came from.
    field :config, :map, default: %{}
    field :config_digest, :string, default: "none"
    # CRAP strictly above this is a violation for diffing and CI gates.
    # nil until the engine persists the effective threshold at run time.
    field :threshold, :float
    # Explicitly protected baseline: retention never expires its details.
    field :pinned, :boolean, default: false
    # Set when retention dropped this scan's findings — summaries, directory
    # aggregates, and the manifest survive; diffs and explanations do not.
    field :details_expired_at, :utc_datetime_usec
    field :error, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    has_many :findings, PoopBags.Catalog.Finding

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(scan, attrs) do
    scan
    |> cast(attrs, [:project_path, :label, :assumed_coverage, :threshold])
    |> validate_required([:project_path])
    |> validate_number(:assumed_coverage,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> validate_number(:threshold, greater_than_or_equal_to: 0.0)
    |> validate_directory_exists()
    |> put_change(:status, "queued")
  end

  def statuses, do: @statuses

  def running?(%__MODULE__{status: status}), do: status in ~w(queued running)

  def finished?(%__MODULE__{status: status}), do: status in ~w(done error)

  # Retention marker: per-function details (findings) exist only for finished,
  # unexpired scans. A queued/running/error scan has no findings either — it is
  # unavailable, never "empty". Expired scans keep summary, directory
  # aggregates, and manifest; they cannot support diffs, listings, or
  # explanations.
  def details_available?(%__MODULE__{status: "done", details_expired_at: nil}), do: true
  def details_available?(%__MODULE__{}), do: false

  defp validate_directory_exists(changeset) do
    case get_change(changeset, :project_path) do
      nil ->
        changeset

      path when is_binary(path) ->
        path = Path.expand(path)

        cond do
          File.dir?(path) -> put_change(changeset, :project_path, path)
          true -> add_error(changeset, :project_path, "is not an existing directory")
        end
    end
  end
end
