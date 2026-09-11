defmodule TimelessUI.Repo.Migrations.IndexEnabledPollerSchedules do
  use Ecto.Migration

  def change do
    create index(:poller_schedules, [:enabled], where: "enabled = 1")
  end
end
