defmodule TimelessUI.Repo.Migrations.CreatePrometheusTargets do
  use Ecto.Migration

  def change do
    create table(:prometheus_targets) do
      add :job_name, :string, null: false
      add :scheme, :string, null: false, default: "http"
      add :address, :string, null: false
      add :metrics_path, :string, null: false, default: "/metrics"
      add :scrape_interval, :integer, null: false, default: 30
      add :scrape_timeout, :integer, null: false, default: 10
      add :labels, :map, null: false, default: %{}
      add :auth, :map
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:prometheus_targets, [:job_name])

    create table(:prometheus_target_state, primary_key: false) do
      add :id, :integer, primary_key: true
      add :version, :integer, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    execute(
      "INSERT INTO prometheus_target_state (id, version, inserted_at, updated_at) VALUES (1, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
      "DELETE FROM prometheus_target_state WHERE id = 1"
    )
  end
end
