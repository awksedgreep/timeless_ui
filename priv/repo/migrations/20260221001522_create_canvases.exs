defmodule TimelessUI.Repo.Migrations.CreateCanvases do
  use Ecto.Migration

  def change do
    create table(:canvases) do
      add :name, :string, null: false
      add :data, :text, null: false

      timestamps()
    end

    create unique_index(:canvases, [:name])
  end
end
