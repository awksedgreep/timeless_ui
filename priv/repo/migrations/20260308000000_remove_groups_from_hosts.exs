defmodule TimelessUI.Repo.Migrations.RemoveGroupsFromHosts do
  use Ecto.Migration

  def change do
    alter table(:poller_hosts) do
      remove :groups, :text, default: "{}"
    end
  end
end
