defmodule TimelessUI.Poller.SnmpTables do
  @moduledoc """
  Context module for SNMP table and column definitions.
  """

  import Ecto.Query

  alias TimelessUI.Repo
  alias TimelessUI.Poller.Snmp.{Table, Column}

  # ── Table CRUD ─────────────────────────────────────────────────────

  def list_tables do
    Repo.all(from t in Table, order_by: [asc: t.name], preload: [:columns])
  end

  def get_table!(id) do
    Repo.get!(Table, id) |> Repo.preload(:columns)
  end

  def get_table(id) do
    case Repo.get(Table, id) do
      nil -> {:error, :not_found}
      table -> {:ok, Repo.preload(table, :columns)}
    end
  end

  def get_table_by_name(name) do
    Repo.one(from t in Table, where: t.name == ^name, preload: [:columns])
  end

  def create_table(attrs \\ %{}) do
    %Table{}
    |> Table.changeset(attrs)
    |> Repo.insert()
  end

  def update_table(%Table{} = table, attrs) do
    table
    |> Table.changeset(attrs)
    |> Repo.update()
  end

  def delete_table(%Table{} = table) do
    Repo.delete(table)
  end

  def change_table(%Table{} = table, attrs \\ %{}) do
    Table.changeset(table, attrs)
  end

  # ── Column CRUD ────────────────────────────────────────────────────

  def list_columns(%Table{} = table) do
    Repo.all(from c in Column, where: c.snmp_table_id == ^table.id, order_by: [asc: c.column_id])
  end

  def get_column!(id) do
    Repo.get!(Column, id)
  end

  def create_column(%Table{} = table, attrs) do
    %Column{}
    |> Column.changeset(Map.put(attrs, :snmp_table_id, table.id))
    |> Repo.insert()
  end

  def update_column(%Column{} = column, attrs) do
    column
    |> Column.changeset(attrs)
    |> Repo.update()
  end

  def delete_column(%Column{} = column) do
    Repo.delete(column)
  end

  def change_column(%Column{} = column, attrs \\ %{}) do
    Column.changeset(column, attrs)
  end
end
