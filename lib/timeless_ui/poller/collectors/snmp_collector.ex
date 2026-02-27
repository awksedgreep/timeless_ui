defmodule TimelessUI.Poller.Collectors.SnmpCollector do
  @moduledoc """
  SNMP collector using SnmpKit MultiV2 for high-performance polling.

  Supports two modes:

  ## Table mode (config has "table" key)

  Bulkwalks a known MIB table, parses OIDs into column/index components,
  groups rows, separates metrics from labels, and enriches with foreign key
  lookups. Configured via `snmp_tables` / `snmp_columns` in the database.

      %{"table" => "ifXTable", "community" => "public"}

  ## Raw OID mode (config has "oids" key)

  Direct SNMP get/walk/bulkwalk against explicit OIDs.

      %{
        "community" => "public",
        "timeout" => 10000,
        "max_repetitions" => 40,
        "port" => 161,
        "oids" => [
          %{"oid" => "1.3.6.1.2.1.1.1.0", "name" => "sysDescr"},
          %{"oid" => "1.3.6.1.2.1.2.2.1.10", "name" => "ifInOctets"}
        ],
        "oid_names" => %{
          "1.3.6.1.2.1.1.1.0" => "sysDescr"
        }
      }
  """

  @behaviour TimelessUI.Poller.Collector

  alias TimelessUI.Poller.Snmp.TableLoader

  require Logger

  @impl true
  def init(_config), do: :ok

  @impl true
  def validate_config(config) when is_map(config) do
    cond do
      Map.has_key?(config, "table") or Map.has_key?(config, :table) ->
        table_name = Map.get(config, "table") || Map.get(config, :table)

        case TableLoader.get_table(table_name) do
          nil -> {:error, "unknown SNMP table '#{table_name}'"}
          _table -> :ok
        end

      Map.has_key?(config, "oids") or Map.has_key?(config, :oids) ->
        oids = Map.get(config, "oids") || Map.get(config, :oids) || []

        if is_list(oids) and length(oids) > 0 do
          :ok
        else
          {:error, "oids must be a non-empty list"}
        end

      true ->
        {:error, "config must have either 'table' or 'oids'"}
    end
  end

  def validate_config(_), do: {:error, "config must be a map"}

  @impl true
  def execute(host, request, config, opts \\ []) do
    table_name = Map.get(config, "table") || Map.get(config, :table)

    if table_name do
      execute_table_mode(host, request, config, table_name, opts)
    else
      execute_raw_oid_mode(host, request, config, opts)
    end
  rescue
    e ->
      Logger.error("SNMP error for #{host.name}: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  # ── Table mode ──────────────────────────────────────────────────────

  defp execute_table_mode(host, _request, config, table_name, opts) do
    case TableLoader.get_table(table_name) do
      nil ->
        Logger.error("SNMP table '#{table_name}' not found")
        {:error, "unknown table '#{table_name}'"}

      table ->
        timeout = get_config(config, :timeout, Keyword.get(opts, :snmp_timeout_ms, 30_000))
        max_rep = get_config(config, :max_repetitions, 40)
        community = get_config(config, :community, "public")
        port = get_config(config, :port, nil) || get_host_config(host, :port)
        ts = System.system_time(:millisecond)

        base_opts =
          [
            community: community,
            timeout: timeout,
            version: :v2c
          ]
          |> maybe_put(:port, port)

        case execute_table_walk(host, table, base_opts, max_rep) do
          {:ok, varbinds} ->
            metrics = build_table_metrics(host.name, table, varbinds, ts)
            {:ok, metrics}

          {:error, reason} ->
            Logger.error("SNMP table walk failed for #{host.name}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  defp execute_table_walk(host, table, base_opts, max_rep) do
    base_target = host.ip || host.name
    community = Keyword.get(base_opts, :community, "public")
    timeout = Keyword.get(base_opts, :timeout, 30_000)
    port = Keyword.get(base_opts, :port)

    target =
      if port, do: "#{base_target}:#{port}", else: base_target

    request_opts =
      [
        community: community,
        max_repetitions: max_rep,
        timeout: timeout,
        version: :v2c
      ]

    case SnmpKit.SnmpMgr.MultiV2.walk_multi([{target, table.base_oid, request_opts}]) do
      [{:ok, varbinds}] when is_list(varbinds) ->
        {:ok, varbinds}

      [{:error, reason}] ->
        {:error, reason}

      other ->
        Logger.warning("Unexpected SNMP walk result: #{inspect(other)}")
        {:error, :unexpected_result}
    end
  end

  defp build_table_metrics(host_name, table, varbinds, ts) do
    # Step 1: Parse varbinds and group by index key
    indexed_data =
      Enum.reduce(varbinds, %{}, fn vb, acc ->
        oid = to_string(vb[:oid] || vb["oid"])

        case TableLoader.parse_oid(oid, table) do
          {:ok, %{column_id: column_id, indices: indices}} ->
            case TableLoader.get_column(table, column_id) do
              nil ->
                acc

              column ->
                index_key = TableLoader.build_index_key(indices)
                value = extract_table_value(vb, column)

                acc
                |> Map.put_new(index_key, %{})
                |> put_in([index_key, column.name], value)
                |> put_in([index_key, :_indices], indices)
            end

          {:error, _} ->
            acc
        end
      end)

    # Step 2: For each row, emit one metric per metric-column with labels
    Enum.flat_map(indexed_data, fn {_index_key, row_data} ->
      base_labels = build_base_labels(host_name, table, row_data)

      table
      |> TableLoader.get_metric_columns()
      |> Enum.filter(fn col -> Map.has_key?(row_data, col.name) end)
      |> Enum.map(fn col ->
        %{
          name: col.name,
          host: host_name,
          type: col.type,
          labels: base_labels,
          val: Map.get(row_data, col.name),
          ts: ts
        }
      end)
    end)
  end

  defp extract_table_value(vb, column) do
    value = vb[:value] || vb["value"]
    formatted = vb[:formatted] || vb["formatted"]

    if column.is_metric do
      to_float(value)
    else
      safe_string(formatted || value)
    end
  end

  defp build_base_labels(host_name, table, row_data) do
    # Start with index values
    indices = Map.get(row_data, :_indices, %{})

    index_labels =
      Map.new(indices, fn {k, v} -> {to_string(k), to_string(v)} end)

    # Add label columns
    label_data =
      table
      |> TableLoader.get_label_columns()
      |> Enum.reduce(%{}, fn col, acc ->
        case Map.get(row_data, col.name) do
          nil -> acc
          value -> Map.put(acc, col.name, to_string(value))
        end
      end)

    index_labels
    |> Map.merge(label_data)
    |> Map.put("host", host_name)
  end

  defp safe_string(value) when is_binary(value) do
    if String.valid?(value) and String.printable?(value) do
      value
    else
      case byte_size(value) do
        6 -> format_mac(value)
        4 -> format_ipv4(value)
        _ -> "hex:" <> Base.encode16(value, case: :lower)
      end
    end
  end

  defp safe_string(value) when is_list(value), do: value |> to_string() |> safe_string()
  defp safe_string(value), do: to_string(value)

  defp format_mac(<<a, b, c, d, e, f>>) do
    [a, b, c, d, e, f]
    |> Enum.map(&(&1 |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")))
    |> Enum.join(":")
  end

  defp format_ipv4(<<a, b, c, d>>), do: Enum.join([a, b, c, d], ".")

  # ── Raw OID mode ────────────────────────────────────────────────────

  defp execute_raw_oid_mode(host, request, config, opts) do
    timeout = get_config(config, :timeout, Keyword.get(opts, :snmp_timeout_ms, 30_000))
    max_rep = get_config(config, :max_repetitions, 40)
    community = get_config(config, :community, "public")
    oids = get_config(config, :oids, [])
    port = get_config(config, :port, nil) || get_host_config(host, :port)
    oid_names = get_config(config, :oid_names, %{})
    ts = System.system_time(:millisecond)

    base_target = host.ip || host.name
    target = if port, do: "#{base_target}:#{port}", else: base_target
    type = request.type

    base_opts =
      [
        community: community,
        timeout: timeout,
        version: :v2c
      ]

    task =
      Task.async(fn ->
        execute_snmp_operation(type, target, oids, base_opts, max_rep)
      end)

    results =
      try do
        Task.await(task, timeout + 1000)
      catch
        :exit, {:timeout, _} ->
          Logger.debug("SNMP timeout after #{timeout}ms for host=#{host.name}")
          Task.shutdown(task, :brutal_kill)
          []
      end

    metrics = build_metrics(host.name, results, oid_names, ts)
    {:ok, metrics}
  end

  # Private Functions

  defp execute_snmp_operation(type, target, oids, base_opts, max_rep) do
    case type do
      "snmpget" ->
        targets = Enum.map(oids, fn oid -> {target, extract_oid(oid), base_opts} end)
        SnmpKit.SnmpMgr.MultiV2.get_multi(targets)

      "snmpwalk" ->
        targets =
          Enum.map(oids, fn oid ->
            {target, extract_oid(oid), Keyword.put(base_opts, :max_repetitions, max_rep)}
          end)

        SnmpKit.SnmpMgr.MultiV2.walk_multi(targets)

      "snmpbulkwalk" ->
        targets =
          Enum.map(oids, fn oid ->
            {target, extract_oid(oid), Keyword.put(base_opts, :max_repetitions, max_rep)}
          end)

        SnmpKit.SnmpMgr.MultiV2.get_bulk_multi(targets)

      _ ->
        Logger.warning("Unknown SNMP type: #{type}, defaulting to walk")

        targets =
          Enum.map(oids, fn oid ->
            {target, extract_oid(oid), Keyword.put(base_opts, :max_repetitions, max_rep)}
          end)

        SnmpKit.SnmpMgr.MultiV2.walk_multi(targets)
    end
  end

  defp extract_oid(oid) when is_map(oid), do: Map.get(oid, "oid") || Map.get(oid, :oid)
  defp extract_oid(oid) when is_binary(oid), do: oid
  defp extract_oid(oid), do: to_string(oid)

  defp build_metrics(host_name, results, oid_names, ts) do
    results
    |> List.wrap()
    |> Enum.flat_map(fn
      {:ok, %{} = vb} ->
        [varbind_to_metric(host_name, vb, oid_names, ts)]

      {:ok, list} when is_list(list) ->
        Enum.map(list, &varbind_to_metric(host_name, &1, oid_names, ts))

      {:error, reason} ->
        Logger.debug("SNMP error result: #{inspect(reason)}")
        []

      other when is_list(other) ->
        Enum.map(other, &varbind_to_metric(host_name, &1, oid_names, ts))

      _ ->
        []
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp varbind_to_metric(host_name, %{} = vb, oid_names, ts) do
    oid = vb[:oid] || vb["oid"]
    type = vb[:type] || vb["type"]
    value = vb[:value] || vb["value"]
    name = vb[:name] || vb["name"]

    metric_name = name || resolve_metric_name(oid, oid_names)

    case extract_value(type, value, vb) do
      {:numeric, val} ->
        %{
          name: metric_name,
          host: host_name,
          type: to_string(type),
          labels: %{"oid" => to_string(oid)},
          val: val,
          val_type: :numeric,
          ts: ts
        }

      {:text, val} ->
        %{
          name: metric_name,
          host: host_name,
          type: to_string(type),
          labels: %{"oid" => to_string(oid)},
          val: val,
          val_type: :text,
          ts: ts
        }

      :skip ->
        nil
    end
  end

  defp varbind_to_metric(_host_name, _, _oid_names, _ts), do: nil

  defp extract_value(type, value, _vb)
       when type in [:integer, :counter32, :counter64, :gauge32, :timeticks] do
    {:numeric, to_float(value)}
  end

  defp extract_value(type, value, vb)
       when type in [:octet_string, :string, :object_identifier, :ip_address, :opaque] do
    formatted = vb[:formatted] || vb["formatted"]
    {:text, safe_string(formatted || value)}
  end

  defp extract_value(_type, _value, _vb), do: :skip

  defp to_float(v) when is_integer(v), do: v * 1.0
  defp to_float(v) when is_float(v), do: v

  defp to_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp to_float(_), do: 0.0

  defp resolve_metric_name(oid, oid_names) do
    oid_str = to_string(oid)

    case Map.get(oid_names, oid_str) do
      nil ->
        oid_str
        |> String.split(".")
        |> Enum.take(-2)
        |> Enum.join("_")

      name ->
        name
    end
  end

  defp get_config(config, key, default) do
    Map.get(config, to_string(key)) || Map.get(config, key) || default
  end

  defp get_host_config(%{config: config}, key) when is_map(config) do
    Map.get(config, to_string(key)) || Map.get(config, key)
  end

  defp get_host_config(_, _), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
