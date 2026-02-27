defmodule TimelessUI.Poller.Snmp.TableLoader do
  @moduledoc """
  Ecto-backed SNMP table loader.

  Reads table definitions from SQLite (snmp_tables, snmp_columns) and provides
  helpers for OID parsing, column classification, and index key building.
  """

  import Ecto.Query

  alias TimelessUI.Repo
  alias TimelessUI.Poller.Snmp.{Table, Column}

  @metric_types ~w(counter32 counter64 gauge gauge32 integer time_ticks)
  @label_types ~w(string octet_string ip_address object_identifier opaque)

  @doc """
  Get table definition by name.

  Returns a map with `:name`, `:base_oid`, `:index_pattern`, and `:columns`
  (keyed by column_id), or `nil` if not found.
  """
  def get_table(table_name) do
    case Repo.one(from t in Table, where: t.name == ^table_name, preload: [:columns]) do
      nil -> nil
      table -> to_table_def(table)
    end
  end

  @doc """
  Parse an OID and extract column_id and indices based on the table's index_pattern.

  ## Examples

      iex> table = %{base_oid: "1.3.6.1.2.1.31.1.1.1", index_pattern: ".{column}.{ifIndex}"}
      iex> TableLoader.parse_oid("1.3.6.1.2.1.31.1.1.1.6.3", table)
      {:ok, %{column_id: 6, indices: %{"ifIndex" => 3}}}
  """
  def parse_oid(oid, table) do
    base_oid = table.base_oid
    prefix = base_oid <> "."

    if String.starts_with?(oid, prefix) do
      remainder = String.trim_leading(oid, prefix)
      parts = String.split(remainder, ".")

      parse_with_pattern(parts, table.index_pattern)
    else
      {:error, :wrong_base_oid}
    end
  end

  @doc """
  Look up a column by column_id from the table's columns map.
  """
  def get_column(table, column_id) do
    Map.get(table.columns, column_id)
  end

  @doc """
  Get all metric columns (numeric data types).
  """
  def get_metric_columns(table) do
    table.columns
    |> Map.values()
    |> Enum.filter(& &1.is_metric)
  end

  @doc """
  Get all label columns (string/identifier data types).
  """
  def get_label_columns(table) do
    table.columns
    |> Map.values()
    |> Enum.filter(& &1.is_label)
  end

  @doc """
  Build an index key string from an indices map.

  ## Examples

      iex> TableLoader.build_index_key(%{"ifIndex" => 1})
      "1"

      iex> TableLoader.build_index_key(%{"ifIndex" => 1, "cmIndex" => 2})
      "1.2"
  """
  def build_index_key(indices) when is_map(indices) do
    indices
    |> Map.values()
    |> Enum.join(".")
  end

  # Private helpers

  defp to_table_def(%Table{} = table) do
    columns =
      table.columns
      |> Enum.map(&to_column_def/1)
      |> Map.new(fn col -> {col.oid_suffix, col} end)

    %{
      name: table.name,
      base_oid: table.base_oid,
      index_pattern: table.index_pattern,
      columns: columns
    }
  end

  defp to_column_def(%Column{} = col) do
    %{
      oid_suffix: col.column_id,
      name: col.name,
      type: col.data_type,
      is_metric: col.data_type in @metric_types,
      is_label: col.data_type in @label_types,
      description: col.description
    }
  end

  defp parse_with_pattern(parts, ".{column}.{ifIndex}") do
    case parts do
      [column_id, index] ->
        {:ok,
         %{
           column_id: String.to_integer(column_id),
           indices: %{"ifIndex" => String.to_integer(index)}
         }}

      _ ->
        {:error, :parse_failed}
    end
  end

  defp parse_with_pattern(parts, ".{column}.{ifIndex}.{cmIndex}") do
    case parts do
      [column_id, if_index, cm_index] ->
        {:ok,
         %{
           column_id: String.to_integer(column_id),
           indices: %{
             "ifIndex" => String.to_integer(if_index),
             "cmIndex" => String.to_integer(cm_index)
           }
         }}

      _ ->
        {:error, :parse_failed}
    end
  end

  defp parse_with_pattern(parts, _pattern) do
    # Generic: first part is column_id, rest are numbered indices
    case parts do
      [column_id | index_parts] ->
        indices =
          index_parts
          |> Enum.with_index(1)
          |> Map.new(fn {value, idx} ->
            {"index#{idx}", String.to_integer(value)}
          end)

        {:ok, %{column_id: String.to_integer(column_id), indices: indices}}

      _ ->
        {:error, :parse_failed}
    end
  end
end
