defmodule TimelessUI.Poller.Snmp.Column do
  @moduledoc """
  Ecto schema for SNMP column definitions within a table.

  Columns define:
  - `name`: Column name (e.g., "ifHCInOctets")
  - `column_id`: The OID column number (e.g., 6)
  - `data_type`: The SNMP type as string (e.g., "counter64", "gauge32", "string")
  - `is_index`: Whether this column is part of the table index
  - `foreign_table` / `foreign_column`: Optional cross-table enrichment references
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias TimelessUI.Poller.Snmp.Table

  @valid_data_types ~w(counter32 counter64 gauge gauge32 integer string
                       octet_string ip_address object_identifier time_ticks opaque)

  schema "snmp_columns" do
    field :name, :string
    field :column_id, :integer
    field :data_type, :string
    field :is_index, :boolean, default: false
    field :foreign_table, :string
    field :foreign_column, :string
    field :description, :string

    belongs_to :snmp_table, Table, foreign_key: :snmp_table_id

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name column_id data_type)a
  @optional_fields ~w(is_index foreign_table foreign_column description snmp_table_id)a

  def changeset(column, attrs) do
    column
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:data_type, @valid_data_types)
    |> foreign_key_constraint(:snmp_table_id)
    |> unique_constraint([:snmp_table_id, :name])
    |> unique_constraint([:snmp_table_id, :column_id])
  end

  @doc """
  Convert the string data_type to an atom.
  """
  def data_type_atom(%__MODULE__{data_type: dt}), do: String.to_existing_atom(dt)

  def valid_data_types, do: @valid_data_types
end
