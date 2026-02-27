defmodule TimelessUI.Poller.Snmp.Table do
  @moduledoc """
  Ecto schema for SNMP table definitions.

  An SNMP table defines:
  - `base_oid`: The root OID for the table (e.g., "1.3.6.1.2.1.31.1.1.1")
  - `name`: The table name (e.g., "ifXTable")
  - `index_pattern`: How to parse the OID remainder (e.g., ".{column}.{ifIndex}")
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias TimelessUI.Poller.Snmp.Column

  schema "snmp_tables" do
    field :name, :string
    field :base_oid, :string
    field :index_pattern, :string
    field :description, :string

    has_many :columns, Column, foreign_key: :snmp_table_id

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name base_oid index_pattern)a
  @optional_fields ~w(description)a

  def changeset(table, attrs) do
    table
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:name)
    |> unique_constraint(:base_oid)
  end
end
