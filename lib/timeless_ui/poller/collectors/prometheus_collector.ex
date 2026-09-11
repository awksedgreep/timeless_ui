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
    ts = System.system_time(:second)

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
      {:ok, [scrape_failure_metric(host, System.system_time(:second))]}
  end

  @doc "Fetch raw exposition bytes for the Rust parser path."
  def execute_raw(host, _request, config, opts \\ []) do
    timeout = Keyword.get(opts, :prometheus_timeout_ms, 5_000)
    scheme = get_config(config, :scheme, "http")
    port = get_config(config, :port, default_port(scheme))
    path = get_config(config, :path, "/metrics")
    target = host.ip || host.name
    url = "#{scheme}://#{target}:#{port}#{path}"

    req_opts = [
      connect_options: [timeout: timeout],
      receive_timeout: timeout,
      decode_body: false
    ]

    req_opts = maybe_add_auth(req_opts, config["auth"])

    case Req.get(url, req_opts) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status, host.name}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  rescue
    error -> {:error, {:scrape, host.name, Exception.message(error)}}
  end

  @doc false
  def failure_metric(host, ts), do: scrape_failure_metric(host, ts)

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
    parse_prometheus_lines(body, host_name, ts, [])
    |> Enum.reverse()
  end

  defp parse_prometheus_lines("", _host_name, _ts, metrics), do: metrics

  defp parse_prometheus_lines(body, host_name, ts, metrics) do
    {line, rest} =
      case :binary.match(body, "\n") do
        {index, 1} ->
          {binary_part(body, 0, index), binary_part(body, index + 1, byte_size(body) - index - 1)}

        :nomatch ->
          {body, ""}
      end

    metrics =
      case parse_metric_line(trim_cr(line), host_name, ts) do
        nil -> metrics
        metric -> [metric | metrics]
      end

    parse_prometheus_lines(rest, host_name, ts, metrics)
  end

  defp parse_metric_line("", _host_name, _ts), do: nil
  defp parse_metric_line(<<"#", _rest::binary>>, _host_name, _ts), do: nil

  defp parse_metric_line(line, host_name, ts) do
    with {:ok, name, labels, value_text} <- split_sample(line),
         true <- valid_metric_name?(name),
         {value, _rest} <- Float.parse(value_text) do
      %{
        name: name,
        host: host_name,
        type: "gauge",
        labels: labels,
        val: value,
        ts: ts
      }
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp split_sample(line) do
    case :binary.match(line, "{") do
      {open, 1} ->
        after_open = binary_part(line, open + 1, byte_size(line) - open - 1)

        case :binary.match(after_open, "}") do
          {close, 1} ->
            name = binary_part(line, 0, open)
            labels = binary_part(after_open, 0, close)
            rest = binary_part(after_open, close + 1, byte_size(after_open) - close - 1)

            with {:ok, value} <- first_token(rest) do
              {:ok, name, parse_labels(labels), value}
            end

          :nomatch ->
            :error
        end

      :nomatch ->
        with {:ok, name, rest} <- name_and_rest(line),
             {:ok, value} <- first_token(rest) do
          {:ok, name, %{}, value}
        end
    end
  end

  defp name_and_rest(line) do
    case :binary.match(line, [" ", "\t"]) do
      {index, 1} when index > 0 ->
        {:ok, binary_part(line, 0, index), binary_part(line, index, byte_size(line) - index)}

      _ ->
        :error
    end
  end

  defp first_token(text) do
    text = String.trim_leading(text)

    case :binary.match(text, [" ", "\t"]) do
      {index, 1} when index > 0 -> {:ok, binary_part(text, 0, index)}
      :nomatch when text != "" -> {:ok, text}
      _ -> :error
    end
  end

  defp valid_metric_name?(<<first, rest::binary>>)
       when first in ?a..?z or first in ?A..?Z or first in [?:, ?_],
       do: valid_metric_name_rest?(rest)

  defp valid_metric_name?(_name), do: false

  defp valid_metric_name_rest?(<<>>), do: true

  defp valid_metric_name_rest?(<<char, rest::binary>>)
       when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in [?:, ?_],
       do: valid_metric_name_rest?(rest)

  defp valid_metric_name_rest?(_rest), do: false

  defp trim_cr(line) do
    if byte_size(line) > 0 and :binary.last(line) == ?\r,
      do: binary_part(line, 0, byte_size(line) - 1),
      else: line
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
