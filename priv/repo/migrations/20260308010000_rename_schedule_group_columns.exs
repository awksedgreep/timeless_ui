defmodule TimelessUI.Repo.Migrations.RenameScheduleGroupColumns do
  use Ecto.Migration

  def change do
    alter table(:poller_schedules) do
      add :host_tags, :string, default: ""
      add :request_tags, :string, default: ""
    end

    alter table(:poller_requests) do
      add :tags, :string, default: ""
    end

    alter table(:poller_schedules) do
      remove :host_groups, :text, default: "{}"
      remove :request_groups, :text, default: "{}"
    end
  end
end
