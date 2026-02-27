defmodule TimelessUI.Repo.Migrations.CreatePollerTables do
  use Ecto.Migration

  def change do
    create table(:poller_hosts) do
      add :name, :string, null: false
      add :ip, :string, null: false
      add :type, :string, null: false, default: "generic"
      add :status, :string, null: false, default: "active"
      add :config, :text, default: "{}"
      add :groups, :text, default: "{}"
      add :tags, :text, default: "[]"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:poller_hosts, [:name])

    create table(:poller_requests) do
      add :name, :string, null: false
      add :type, :string, null: false
      add :groups, :text, default: "{}"
      add :config, :text, default: "{}"
      add :description, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:poller_requests, [:name])

    create table(:poller_schedules) do
      add :name, :string, null: false
      add :cron, :string, null: false
      add :host_groups, :text, default: "{}"
      add :request_groups, :text, default: "{}"
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:poller_schedules, [:name])
  end
end
