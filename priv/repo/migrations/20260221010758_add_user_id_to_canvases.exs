defmodule TimelessUI.Repo.Migrations.AddUserIdToCanvases do
  use Ecto.Migration

  def change do
    alter table(:canvases) do
      add :user_id, references(:users, on_delete: :delete_all)
    end

    # Drop the old name-only unique index and replace with user+name
    drop unique_index(:canvases, [:name])
    create unique_index(:canvases, [:user_id, :name])
    create index(:canvases, [:user_id])
  end
end
