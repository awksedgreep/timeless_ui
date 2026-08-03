defmodule TimelessUI.Repo.Migrations.AddMustChangePasswordToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :must_change_password, :boolean, default: false, null: false
    end
  end
end
