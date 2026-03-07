defmodule TimelessUI.Repo.Migrations.RenameEmailToUsername do
  use Ecto.Migration

  def change do
    rename table(:users), :email, to: :username
    # The index name stays the same in SQLite, but let's recreate for clarity
    drop_if_exists index(:users, [:email])
    create unique_index(:users, [:username])
  end
end
