defmodule TimelessUI.Poller.Snmp.TableLoader do
  @moduledoc """
  Ecto-backed SNMP table loader.

  Reads table definitions from SQLite (snmp_tables, snmp_columns) and provides
  helpers for OID parsing, column classification, and index key building.
  """

  use GenServer

  import Ecto.Query

  alias TimelessUI.Repo
  alias TimelessUI.Poller.Snmp.{Table, Column}

  @metric_types ~w(counter32 counter64 gauge gauge32 integer time_ticks)
  @label_types ~w(string octet_string ip_address object_identifier opaque)
  @cache __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@cache, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Get table definition by name.

  Returns a map with `:name`, `:base_oid`, `:index_pattern`, and `:columns`
  (keyed by column_id), or `nil` if not found.
  """
  def get_table(table_name) do
    case cached(table_name) do
      {:ok, table} ->
        table

      :miss ->
        case Repo.one(from t in Table, where: t.name == ^table_name, preload: [:columns]) do
          nil ->
            cache(table_name, nil)
            nil

          table ->
            definition = to_table_def(table)
            cache(table_name, definition)
            definition
        end
    end
  end

  @doc "Invalidate one cached table definition after a control-plane write."
  def invalidate(table_name) when is_binary(table_name) do
    if cache_available?(), do: :ets.delete(@cache, table_name)
    :ok
  end

  @doc "Invalidate all cached definitions after a table or column write."
  def invalidate_all do
    if cache_available?(), do: :ets.delete_all_objects(@cache)
    :ok
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

      iex> TableLoader.build_index_key(%{"ifIndex" => 1, "cmIndex" => 2}, ["ifIndex", "cmIndex"])
      "1.2"
  """
  def build_index_key(indices, index_names \\ nil) when is_map(indices) do
    index_names =
      if index_names in [nil, []], do: indices |> Map.keys() |> Enum.sort(), else: index_names

    index_names
    |> Enum.map(&Map.fetch!(indices, &1))
    |> Enum.join(".")
  end

  defp index_names(index_pattern) do
    index_pattern
    |> String.split("{")
    |> Enum.drop(1)
    |> Enum.map(fn fragment -> fragment |> String.split("}", parts: 2) |> hd() end)
    |> Enum.reject(&(&1 == "column"))
  end

  @doc """
  Get required table names (dependencies) for this table.
  Scans columns for foreign_table references and returns unique table names.
  """
  def get_required_tables(table) do
    table.columns
    |> Map.values()
    |> Enum.filter(& &1.foreign_table)
    |> Enum.map(& &1.foreign_table)
    |> Enum.uniq()
  end

  @doc """
  Get columns that have foreign key references.
  """
  def get_foreign_keys(table) do
    table.columns
    |> Map.values()
    |> Enum.filter(& &1.foreign_table)
  end

  @doc """
  Enrich row data with foreign key lookups.

  Returns a map of label_name => value for each resolved foreign key.
  `foreign_table_data` is `%{table_name => %{index_key => %{col_name => value, ...}}}`.
  """
  def enrich_with_foreign_keys(row_data, table, foreign_table_data) do
    fk_columns = get_foreign_keys(table)

    Enum.reduce(fk_columns, %{}, fn fk_col, labels ->
      # Determine the lookup key into the foreign table
      lookup_key =
        if fk_col.is_index do
          # Index column — use the row's matching index value
          indices = Map.get(row_data, :_indices, %{})

          case Map.get(indices, fk_col.name) do
            nil -> nil
            val -> to_string(val)
          end
        else
          # Data column — the column's value IS the foreign index
          case Map.get(row_data, fk_col.name) do
            nil -> nil
            val when is_float(val) -> to_string(trunc(val))
            val -> to_string(val)
          end
        end

      if lookup_key do
        foreign_row = get_in(foreign_table_data, [fk_col.foreign_table, lookup_key])

        case foreign_row && Map.get(foreign_row, fk_col.foreign_column) do
          nil -> labels
          value -> Map.put(labels, fk_col.foreign_column, to_string(value))
        end
      else
        labels
      end
    end)
  end

  # Private helpers

  defp cached(table_name) do
    if cache_enabled?() and cache_available?() do
      case :ets.lookup(@cache, table_name) do
        [{^table_name, table}] -> {:ok, table}
        [] -> :miss
      end
    else
      :miss
    end
  end

  defp cache(table_name, table) do
    if cache_enabled?() and cache_available?(), do: :ets.insert(@cache, {table_name, table})
  end

  defp cache_enabled? do
    Application.get_env(:timeless_ui, :snmp_table_cache, enabled: true)
    |> Keyword.get(:enabled, true)
  end

  defp cache_available?, do: :ets.whereis(@cache) != :undefined

  defp to_table_def(%Table{} = table) do
    columns =
      table.columns
      |> Enum.map(&to_column_def/1)
      |> Map.new(fn col -> {col.oid_suffix, col} end)

    %{
      name: table.name,
      base_oid: table.base_oid,
      index_pattern: table.index_pattern,
      index_names: index_names(table.index_pattern),
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
      is_index: col.is_index,
      foreign_table: col.foreign_table,
      foreign_column: col.foreign_column,
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
