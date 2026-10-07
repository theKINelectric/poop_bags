defmodule PoopBags.Repo.Migrations.Phase3TrendsRetention do
  use Ecto.Migration

  def change do
    alter table(:scans) do
      # Explicitly protected baseline: retention never expires a pinned
      # scan's detailed findings.
      add :pinned, :boolean, null: false, default: false
      # Set when retention drops this scan's findings. Summaries, directory
      # aggregates, and the file manifest survive; function-level diffing,
      # listings, and explanations do not.
      add :details_expired_at, :utc_datetime_usec
    end

    # One aggregate row per (scan, display depth, directory group): the
    # durable hotspot record trends are built from, kept after detail expiry.
    create table(:scan_directories) do
      add :scan_id, references(:scans, on_delete: :delete_all), null: false
      # "(root)", "src", "src/workbench", "src/(direct files)", ...
      add :path, :text, null: false
      # Display level the row belongs to (1 = first segment, 2 = first two).
      add :depth, :integer, null: false, default: 1
      add :files, :integer, null: false, default: 0
      add :functions, :integer, null: false, default: 0
      # Findings with CRAP strictly above the scan's threshold.
      add :violations, :integer, null: false, default: 0
      add :worst_crap, :float, null: false, default: 0.0
      # Sum of max(crap − threshold, 0): above-threshold burden, the default
      # hotspot sort. Grows with directory size on purpose — pair it with the
      # violation rate when comparing differently sized directories.
      add :crap_excess, :float, null: false, default: 0.0
      add :measured_functions, :integer, null: false, default: 0
      add :assumed_functions, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:scan_directories, [:scan_id])
    create unique_index(:scan_directories, [:scan_id, :depth, :path])
  end
end
