defmodule TimelessUI.Poller.Collectors.MikrotikRestCollector do
  @moduledoc """
  MikroTik collector for RouterOS v7+ REST API.

  Collects metrics from MikroTik routers using the REST API available
  in RouterOS v7 and later.

  ## Per-request configuration (in request.config)

      %{
        "username" => "admin",
        "password" => "secret",
        "port" => 443,
        "ssl" => true,
        "endpoints" => [
          "/rest/interface",
          "/rest/system/resource"
        ]
      }
  """

  @behaviour TimelessUI.Poller.Collector

  require Logger

  @impl true
  def init(_config), do: :ok

  @impl true
  def validate_config(config) when is_map(config) do
    cond do
      !Map.has_key?(config, "username") and !Map.has_key?(config, :username) ->
        {:error, "username is required for MikroTik"}

      !Map.has_key?(config, "password") and !Map.has_key?(config, :password) ->
        {:error, "password is required for MikroTik"}

      !Map.has_key?(config, "endpoints") and !Map.has_key?(config, :endpoints) ->
        {:error, "endpoints list is required for MikroTik"}

      true ->
        endpoints = Map.get(config, "endpoints") || Map.get(config, :endpoints) || []

        if is_list(endpoints) and length(endpoints) > 0 do
          :ok
        else
          {:error, "endpoints must be a non-empty list"}
        end
    end
  end

  def validate_config(_), do: {:error, "config must be a map"}

  @impl true
  def execute(host, _request, config, opts \\ []) do
    timeout = Keyword.get(opts, :mikrotik_timeout_ms, 5_000)
    ts = System.system_time(:millisecond)

    username = get_config(config, :username, "admin")
    password = get_config(config, :password, "")
    port = get_config(config, :port, 443)
    ssl = get_config(config, :ssl, port == 443)
    endpoints = get_config(config, :endpoints, [])

    scheme = if ssl, do: "https", else: "http"
    target = host.ip || host.name
    base_url = "#{scheme}://#{target}:#{port}"

    metrics =
      endpoints
      |> Enum.flat_map(fn endpoint ->
        collect_endpoint(base_url, endpoint, username, password, timeout, host.name, ts)
      end)

    {:ok, metrics}
  rescue
    e ->
      Logger.error("MikroTik error for #{host.name}: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  # Private Functions

  defp collect_endpoint(base_url, endpoint, username, password, timeout, host_name, ts) do
    url = base_url <> endpoint

    req_opts = [
      auth: {:basic, "#{username}:#{password}"},
      connect_options: [
        timeout: timeout,
        transport_opts: [verify: :verify_none]
      ],
      receive_timeout: timeout
    ]

    case Req.get(url, req_opts) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        parse_mikrotik_response(body, endpoint, host_name, ts)

      {:ok, %{status: 200, body: body}} when is_map(body) ->
        parse_mikrotik_response([body], endpoint, host_name, ts)

      {:ok, %{status: status}} ->
        Logger.debug("MikroTik HTTP #{status} from #{url}")
        []

      {:error, reason} ->
        Logger.debug("MikroTik error from #{url}: #{inspect(reason)}")
        []
    end
  rescue
    e ->
      Logger.debug("MikroTik error collecting #{endpoint}: #{Exception.message(e)}")
      []
  end

  defp parse_mikrotik_response(items, endpoint, host_name, ts) when is_list(items) do
    metric_prefix = endpoint_to_metric_name(endpoint)

    items
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} ->
      parse_item(item, metric_prefix, index, host_name, ts)
    end)
  end

  defp endpoint_to_metric_name(endpoint) do
    endpoint
    |> String.replace_prefix("/rest/", "")
    |> String.replace("/", "_")
    |> then(&"mikrotik_#{&1}")
  end

  defp parse_item(item, prefix, index, host_name, ts) when is_map(item) do
    item_name = Map.get(item, "name") || Map.get(item, ".id") || to_string(index)

    item
    |> Enum.flat_map(fn {key, value} ->
      parse_field(key, value, prefix, item_name, host_name, ts)
    end)
  end

  defp parse_field(key, value, prefix, item_name, host_name, ts) do
    if String.starts_with?(key, ".") or key in ["name", "id"] do
      []
    else
      metric_name = "#{prefix}_#{key}"

      case value do
        v when is_boolean(v) ->
          [metric(metric_name, host_name, %{"item" => item_name}, bool_val(v), ts)]

        v when is_number(v) ->
          [metric(metric_name, host_name, %{"item" => item_name}, v * 1.0, ts)]

        v when is_binary(v) ->
          case parse_numeric_string(v) do
            {:ok, num} ->
              [metric(metric_name, host_name, %{"item" => item_name}, num, ts)]

            :error ->
              []
          end

        _ ->
          []
      end
    end
  end

  defp metric(name, host_name, labels, val, ts) do
    %{
      name: name,
      host: host_name,
      type: "gauge",
      labels: labels,
      val: val,
      ts: ts
    }
  end

  defp bool_val(true), do: 1.0
  defp bool_val(false), do: 0.0

  defp parse_numeric_string(str) do
    cond do
      Regex.match?(~r/^\d+$/, str) ->
        {:ok, String.to_integer(str) * 1.0}

      Regex.match?(~r/^\d+\.\d+$/, str) ->
        {:ok, String.to_float(str)}

      true ->
        case Regex.run(~r/^([\d.]+)([A-Za-z]+)$/, str) do
          [_, num_str, unit] ->
            with {:ok, num} <- parse_number(num_str),
                 {:ok, multiplier} <- unit_multiplier(unit) do
              {:ok, num * multiplier}
            else
              _ -> :error
            end

          _ ->
            :error
        end
    end
  end

  defp parse_number(str) do
    if String.contains?(str, ".") do
      case Float.parse(str) do
        {f, _} -> {:ok, f}
        :error -> :error
      end
    else
      case Integer.parse(str) do
        {i, _} -> {:ok, i * 1.0}
        :error -> :error
      end
    end
  end

  defp unit_multiplier(unit) do
    case String.downcase(unit) do
      "ms" -> {:ok, 0.001}
      "s" -> {:ok, 1.0}
      "m" -> {:ok, 60.0}
      "h" -> {:ok, 3600.0}
      "d" -> {:ok, 86400.0}
      "b" -> {:ok, 1.0}
      "kb" -> {:ok, 1024.0}
      "mb" -> {:ok, 1024.0 * 1024.0}
      "gb" -> {:ok, 1024.0 * 1024.0 * 1024.0}
      "kib" -> {:ok, 1024.0}
      "mib" -> {:ok, 1024.0 * 1024.0}
      "gib" -> {:ok, 1024.0 * 1024.0 * 1024.0}
      "hz" -> {:ok, 1.0}
      "khz" -> {:ok, 1000.0}
      "mhz" -> {:ok, 1_000_000.0}
      "ghz" -> {:ok, 1_000_000_000.0}
      _ -> :error
    end
  end

  defp get_config(config, key, default) do
    Map.get(config, to_string(key)) || Map.get(config, key) || default
  end
end
