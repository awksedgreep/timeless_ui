defmodule TimelessUI.Poller.Collectors.MikrotikCoreMetrics do
  @moduledoc """
  Inventory-free CHR telemetry: every interface, GRE tunnel, WireGuard
  interface/peer, and VRRP instance returned by RouterOS REST is measured.

  Credentials come from a named environment variable, never the poller DB.
  A failed or malformed REST response emits an explicit failure series.
  """

  require Logger

  @resources [
    resource: "/system/resource",
    health: "/system/health",
    interface: "/interface",
    gre: "/interface/gre",
    wireguard: "/interface/wireguard",
    peer: "/interface/wireguard/peers",
    vrrp: "/interface/vrrp"
  ]

  @counter_fields %{
    "rx-byte" => "routeros_interface_receive_bytes_total",
    "tx-byte" => "routeros_interface_transmit_bytes_total",
    "rx-packet" => "routeros_interface_receive_packets_total",
    "tx-packet" => "routeros_interface_transmit_packets_total",
    "rx-error" => "routeros_interface_receive_errors_total",
    "tx-error" => "routeros_interface_transmit_errors_total"
  }

  def validate_config(config) do
    username = value(config, "username")
    password_env = value(config, "password_env")
    port = value(config, "port", 80)

    cond do
      not is_binary(username) or username == "" ->
        {:error, "username is required"}

      not is_binary(password_env) or not Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, password_env) ->
        {:error, "password_env must name an environment variable"}

      Map.has_key?(config, "password") or Map.has_key?(config, :password) ->
        {:error, "store the password in an environment variable, not poller config"}

      not is_integer(port) or port < 1 or port > 65_535 ->
        {:error, "port must be a valid integer"}

      true ->
        :ok
    end
  end

  def execute(host, config, opts \\ []) do
    ts = System.system_time(:second)

    case validate_config(config) do
      :ok ->
        password_provider = Keyword.get(opts, :password_provider, &System.get_env/1)
        password = password_provider.(value(config, "password_env"))

        if is_binary(password) and password != "" do
          collect(host, config, opts, password, ts)
        else
          Logger.warning("CHR collector credential missing for #{host.name}")
          {:ok, failure_metrics(host.name, ts, "auth")}
        end

      {:error, reason} ->
        Logger.warning("CHR collector configuration invalid for #{host.name}: #{reason}")
        {:ok, failure_metrics(host.name, ts, "config")}
    end
  end

  defp failure_metrics(host, ts, resource) do
    [
      metric("routeros_up", host, 0, ts),
      metric("routeros_collection_success", host, 0, ts, %{"resource" => resource})
    ]
  end

  defp collect(host, config, opts, password, ts) do
    client = Keyword.get(opts, :client, MikrotikApi)
    auth = MikrotikApi.Auth.new(username: value(config, "username"), password: password)
    scheme = if value(config, "ssl", false), do: :https, else: :http
    port = value(config, "port", if(scheme == :https, do: 443, else: 80))
    target = host.ip || host.name

    {results, failures} =
      Enum.reduce(@resources, {[], 0}, fn {resource, path}, {metrics, failures} ->
        case fetch(client, auth, target, path, scheme, port) do
          {:ok, body} ->
            case resource_metrics(resource, body, host.name, ts) do
              {:ok, values} ->
                {[
                   metric("routeros_collection_success", host.name, 1, ts, %{
                     "resource" => to_string(resource)
                   })
                   | values
                 ] ++ metrics, failures}

              :error ->
                Logger.warning("CHR collector received malformed #{resource} from #{host.name}")

                {[
                   metric("routeros_collection_success", host.name, 0, ts, %{
                     "resource" => to_string(resource)
                   })
                   | metrics
                 ], failures + 1}
            end

          {:error, status} ->
            Logger.warning("CHR collector #{resource} failed for #{host.name}, status=#{status}")

            {[
               metric("routeros_collection_success", host.name, 0, ts, %{
                 "resource" => to_string(resource)
               })
               | metrics
             ], failures + 1}
        end
      end)

    {:ok, [metric("routeros_up", host.name, if(failures == 0, do: 1, else: 0), ts) | results]}
  end

  defp fetch(client, auth, target, path, scheme, port) do
    case client.get(auth, target, path, scheme: scheme, port: port) do
      {:ok, body} -> {:ok, body}
      {:error, error} -> {:error, Map.get(error, :status, :transport)}
    end
  rescue
    _ -> {:error, :exception}
  end

  defp resource_metrics(:resource, body, host, ts) when is_map(body) do
    mappings = [
      {"cpu-load", "routeros_cpu_load_percent"},
      {"free-memory", "routeros_memory_free_bytes"},
      {"total-memory", "routeros_memory_total_bytes"},
      {"free-hdd-space", "routeros_disk_free_bytes"},
      {"total-hdd-space", "routeros_disk_total_bytes"}
    ]

    metrics =
      Enum.flat_map(mappings, fn {field, name} ->
        numeric_metric(name, host, body[field], ts)
      end)

    metrics =
      case duration_seconds(body["uptime"]) do
        {:ok, seconds} -> [metric("routeros_uptime_seconds", host, seconds, ts) | metrics]
        :error -> metrics
      end

    info =
      metric("routeros_info", host, 1, ts, %{
        "version" => to_string(body["version"] || "unknown"),
        "board" => to_string(body["board-name"] || "unknown")
      })

    {:ok, [info | metrics]}
  end

  defp resource_metrics(:health, body, host, ts) when is_map(body) do
    numeric =
      Enum.flat_map(body, fn {field, value} ->
        if field in ["temperature", "voltage", "cpu-temperature", "board-temperature1"] do
          numeric_metric("routeros_health_#{String.replace(field, "-", "_")}", host, value, ts)
        else
          []
        end
      end)

    enabled = if body["state"] == "disabled", do: 0, else: 1
    {:ok, [metric("routeros_health_sensor_enabled", host, enabled, ts) | numeric]}
  end

  defp resource_metrics(:interface, body, host, ts) when is_list(body) do
    if Enum.all?(body, &is_map/1), do: interface_metrics(body, host, ts), else: :error
  end

  defp resource_metrics(kind, body, host, ts) when kind in [:gre, :wireguard] and is_list(body) do
    if Enum.all?(body, &is_map/1), do: tunnel_metrics(kind, body, host, ts), else: :error
  end

  defp resource_metrics(:peer, body, host, ts) when is_list(body) do
    if Enum.all?(body, &is_map/1), do: peer_metrics(body, host, ts), else: :error
  end

  defp resource_metrics(:vrrp, body, host, ts) when is_list(body) do
    if Enum.all?(body, &is_map/1), do: vrrp_metrics(body, host, ts), else: :error
  end

  defp resource_metrics(_, _, _, _), do: :error

  defp interface_metrics(body, host, ts) do
    metrics =
      Enum.flat_map(body, fn row ->
        name = row["name"] || row[".id"]
        type = row["type"] || "unknown"
        labels = %{"interface" => name, "interface_type" => type}

        [
          metric("routeros_interface_running", host, bool_value(row["running"]), ts, labels),
          metric("routeros_interface_enabled", host, 1 - bool_value(row["disabled"]), ts, labels)
        ] ++
          Enum.flat_map(@counter_fields, fn {field, metric_name} ->
            numeric_metric(metric_name, host, row[field], ts, labels)
          end)
      end)

    counts =
      body
      |> Enum.frequencies_by(&(&1["type"] || "unknown"))
      |> Enum.map(fn {type, count} ->
        metric("routeros_interface_count", host, count, ts, %{"interface_type" => type})
      end)

    {:ok, metrics ++ counts}
  end

  defp tunnel_metrics(kind, body, host, ts) do
    type = to_string(kind)

    metrics =
      Enum.flat_map(body, fn row ->
        labels = %{"tunnel_type" => type, "tunnel" => row["name"] || row[".id"]}

        [
          metric("routeros_tunnel_running", host, bool_value(row["running"]), ts, labels),
          metric("routeros_tunnel_enabled", host, 1 - bool_value(row["disabled"]), ts, labels)
        ]
      end)

    {:ok,
     [metric("routeros_tunnel_count", host, length(body), ts, %{"tunnel_type" => type}) | metrics]}
  end

  defp peer_metrics(body, host, ts) do
    metrics =
      Enum.flat_map(body, fn row ->
        labels = %{
          "interface" => row["interface"] || "unknown",
          "peer" => row["name"] || row[".id"] || "unknown"
        }

        handshake = duration_seconds(row["last-handshake"])

        [
          metric(
            "routeros_wireguard_peer_enabled",
            host,
            1 - bool_value(row["disabled"]),
            ts,
            labels
          ),
          metric(
            "routeros_wireguard_peer_handshake_seen",
            host,
            if(match?({:ok, _}, handshake), do: 1, else: 0),
            ts,
            labels
          )
        ] ++
          Enum.flat_map(
            [
              {"rx", "routeros_wireguard_peer_receive_bytes_total"},
              {"tx", "routeros_wireguard_peer_transmit_bytes_total"}
            ],
            fn {field, name} -> numeric_metric(name, host, row[field], ts, labels) end
          ) ++
          case handshake do
            {:ok, age} ->
              [metric("routeros_wireguard_peer_handshake_age_seconds", host, age, ts, labels)]

            :error ->
              []
          end
      end)

    {:ok, [metric("routeros_wireguard_peer_count", host, length(body), ts) | metrics]}
  end

  defp vrrp_metrics(body, host, ts) do
    metrics =
      Enum.flat_map(body, fn row ->
        labels = %{"instance" => row["name"] || row[".id"] || "unknown"}

        [
          metric("routeros_vrrp_master", host, bool_value(row["master"]), ts, labels),
          metric("routeros_vrrp_running", host, bool_value(row["running"]), ts, labels)
        ]
      end)

    {:ok, metrics}
  end

  defp numeric_metric(name, host, value, ts, labels \\ %{}) do
    case number(value) do
      {:ok, num} -> [metric(name, host, num, ts, labels)]
      :error -> []
    end
  end

  defp number(value) when is_number(value), do: {:ok, value}

  defp number(value) when is_binary(value) do
    case Integer.parse(value) do
      {num, ""} ->
        {:ok, num}

      _ ->
        case Float.parse(value) do
          {num, ""} -> {:ok, num}
          _ -> :error
        end
    end
  end

  defp number(_), do: :error

  defp bool_value(value) when value in [true, "true", "yes"], do: 1
  defp bool_value(_), do: 0

  defp duration_seconds(value) when is_binary(value) do
    parts = Regex.scan(~r/(\d+)(w|d|h|m|s)/, value)

    if parts != [] and Enum.map_join(parts, "", &hd/1) == value do
      multipliers = %{"w" => 604_800, "d" => 86_400, "h" => 3_600, "m" => 60, "s" => 1}

      {:ok,
       Enum.reduce(parts, 0, fn [_, count, unit], sum ->
         sum + String.to_integer(count) * multipliers[unit]
       end)}
    else
      :error
    end
  end

  defp duration_seconds(_), do: :error

  defp metric(name, host, value, ts, labels \\ %{}) do
    %{name: name, host: host, type: "mikrotik", labels: labels, val: value, ts: ts}
  end

  defp value(config, key, default \\ nil) do
    case Enum.find(config, fn {candidate, _value} -> to_string(candidate) == key end) do
      nil -> default
      {_key, value} -> value
    end
  end
end
