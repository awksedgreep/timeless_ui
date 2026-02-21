defmodule TimelessUI.Repo.Migrations.CreateCanvasAccesses do
  use Ecto.Migration

  def change do
    create table(:canvas_accesses) do
      add :canvas_id, references(:canvases, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false

      timestamps()
    end

    create unique_index(:canvas_accesses, [:canvas_id, :user_id])
    create index(:canvas_accesses, [:user_id])
  end
end
