defmodule PoopBags.Repo.Migrations.Phase2CoverageDiffCi do
  use Ecto.Migration

  def change do
    alter table(:findings) do
      add :end_line, :integer, null: false, default: 1
      # The coverage ratio actually used for scoring, and where it came from.
      add :coverage, :float
      add :coverage_source, :text, null: false, default: "assumed"
    end

    alter table(:scans) do
      # Effective project configuration snapshot (.poopbags.json + overrides).
      add :config, :map, null: false, default: "{}"
      add :config_digest, :text, null: false, default: "none"
      # CRAP strictly above this is a violation; null until the engine
      # persists the effective threshold at run time.
      add :threshold, :float
    end

    create table(:scan_files) do
      add :scan_id, references(:scans, on_delete: :delete_all), null: false
      add :path, :text, null: false
      add :size, :integer, null: false, default: 0
      add :hash, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:scan_files, [:scan_id])
    create index(:scan_files, [:scan_id, :hash])
  end
end
