defmodule TimelessUI.Poller.Collectors.PrometheusCollector do
  @moduledoc """
  Prometheus collector for scraping /metrics endpoints.

  Collects metrics from Prometheus-compatible HTTP endpoints that expose
  metrics in the Prometheus text format.

  ## Per-request configuration (in request.config)

      %{
        "path" => "/metrics",
        "scheme" => "https",
        "port" => 9090,
        "auth" => %{
          "type" => "bearer",
          "token" => "secret_token"
        }
      }
  """

  @behaviour TimelessUI.Poller.Collector

  require Logger

  @impl true
  def init(_config), do: :ok

  @impl true
  def validate_config(config) when is_map(config), do: :ok
  def validate_config(_), do: {:error, "config must be a map"}

  @impl true
  def execute(host, _request, config, opts \\ []) do
    timeout = Keyword.get(opts, :prometheus_timeout_ms, 5_000)
    ts = System.system_time(:millisecond)

    scheme = get_config(config, :scheme, "http")
    port = get_config(config, :port, default_port(scheme))
    path = get_config(config, :path, "/metrics")
    target = host.ip || host.name

    url = "#{scheme}://#{target}:#{port}#{path}"

    req_opts = [
      connect_options: [timeout: timeout],
      receive_timeout: timeout
    ]

    req_opts = maybe_add_auth(req_opts, config["auth"])

    case Req.get(url, req_opts) do
      {:ok, %{status: 200, body: body}} ->
        metrics = parse_prometheus_metrics(body, host.name, ts)
        {:ok, metrics}

      {:ok, %{status: status}} ->
        Logger.debug("Prometheus HTTP #{status} from #{host.name} (#{url})")
        {:ok, [scrape_failure_metric(host, ts)]}

      {:error, reason} ->
        Logger.debug("Prometheus error from #{host.name}: #{inspect(reason)}")
        {:ok, [scrape_failure_metric(host, ts)]}
    end
  rescue
    e ->
      Logger.error("Prometheus error for #{host.name}: #{Exception.message(e)}")
      {:ok, [scrape_failure_metric(host, System.system_time(:millisecond))]}
  end

  # Private Functions

  defp default_port("https"), do: 443
  defp default_port(_), do: 80

  defp get_config(config, key, default) do
    Map.get(config, to_string(key)) || Map.get(config, key) || default
  end

  defp maybe_add_auth(opts, nil), do: opts

  defp maybe_add_auth(opts, %{"type" => "bearer", "token" => token}) do
    Keyword.put(opts, :auth, {:bearer, token})
  end

  defp maybe_add_auth(opts, %{"type" => "basic", "username" => user, "password" => pass}) do
    Keyword.put(opts, :auth, {user, pass})
  end

  defp maybe_add_auth(opts, _), do: opts

  defp scrape_failure_metric(host, ts) do
    %{
      name: "prometheus_scrape_success",
      host: host.name,
      type: "prometheus",
      labels: build_labels(host),
      val: 0,
      ts: ts
    }
  end

  defp build_labels(host) do
    %{
      "host" => host.name,
      "ip" => host.ip,
      "type" => host.type
    }
  end

  defp parse_prometheus_metrics(body, host_name, ts) do
    body
    |> String.split("\n")
    |> Enum.reject(&(String.starts_with?(&1, "#") or String.trim(&1) == ""))
    |> Enum.map(&parse_metric_line(&1, host_name, ts))
    |> Enum.reject(&is_nil/1)
  end

  defp parse_metric_line(line, host_name, ts) do
    case Regex.run(~r/^([a-zA-Z_:][a-zA-Z0-9_:]*)\{([^}]*)\}\s+([\d.eE+\-]+)/, line) do
      [_, name, labels_str, value] ->
        %{
          name: name,
          host: host_name,
          type: "gauge",
          labels: parse_labels(labels_str),
          val: parse_value(value),
          ts: ts
        }

      _ ->
        case Regex.run(~r/^([a-zA-Z_:][a-zA-Z0-9_:]*)\s+([\d.eE+\-]+)/, line) do
          [_, name, value] ->
            %{
              name: name,
              host: host_name,
              type: "gauge",
              labels: %{},
              val: parse_value(value),
              ts: ts
            }

          _ ->
            nil
        end
    end
  rescue
    _ -> nil
  end

  defp parse_value(value_str) do
    case Float.parse(value_str) do
      {num, _} -> num
      :error -> 0.0
    end
  end

  defp parse_labels(""), do: %{}

  defp parse_labels(labels_str) do
    labels_str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [key, value] -> {key, String.trim(value, "\"")}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end
end
