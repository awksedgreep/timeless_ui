defmodule TimelessUI.Repo.Migrations.CreateSnmpTables do
  use Ecto.Migration

  def change do
    create table(:snmp_tables) do
      add :name, :string, null: false
      add :base_oid, :string, null: false
      add :index_pattern, :string, null: false
      add :description, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:snmp_tables, [:name])
    create unique_index(:snmp_tables, [:base_oid])

    create table(:snmp_columns) do
      add :snmp_table_id, references(:snmp_tables, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :column_id, :integer, null: false
      add :data_type, :string, null: false
      add :is_index, :boolean, null: false, default: false
      add :foreign_table, :string
      add :foreign_column, :string
      add :description, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:snmp_columns, [:snmp_table_id, :name])
    create unique_index(:snmp_columns, [:snmp_table_id, :column_id])
    create index(:snmp_columns, [:snmp_table_id])
  end
end
