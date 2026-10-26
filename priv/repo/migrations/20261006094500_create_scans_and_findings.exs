defmodule PoopBags.Repo.Migrations.CreateScansAndFindings do
  use Ecto.Migration

  def change do
    create table(:scans) do
      add :project_path, :text, null: false
      add :label, :text
      add :status, :text, null: false, default: "queued"
      # 0.0 .. 1.0 — coverage assumed for every function when computing CRAP.
      add :assumed_coverage, :float, null: false, default: 0.0
      add :files_total, :integer, null: false, default: 0
      add :files_done, :integer, null: false, default: 0
      add :files_failed, :integer, null: false, default: 0
      add :files_skipped, :integer, null: false, default: 0
      add :functions_total, :integer, null: false, default: 0
      add :worst_crap, :float, null: false, default: 0.0
      add :avg_crap, :float, null: false, default: 0.0
      add :stats, :map, null: false, default: "{}"
      add :error, :text
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:scans, [:status])
    create index(:scans, [:inserted_at])

    create table(:findings) do
      add :scan_id, references(:scans, on_delete: :delete_all), null: false
      add :language, :text, null: false
      add :path, :text, null: false
      add :module_name, :text, null: false, default: ""
      add :function_name, :text, null: false
      add :line, :integer, null: false, default: 1
      add :complexity, :integer, null: false, default: 1
      add :crap, :float, null: false, default: 0.0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:findings, [:scan_id, :crap])
    create index(:findings, [:scan_id, :language])
  end
end
