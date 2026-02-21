defmodule TimelessUI.Repo.Migrations.AddParentIdToCanvases do
  use Ecto.Migration

  def change do
    alter table(:canvases) do
      add :parent_id, references(:canvases, on_delete: :nilify_all)
    end

    create index(:canvases, [:parent_id])
  end
end
