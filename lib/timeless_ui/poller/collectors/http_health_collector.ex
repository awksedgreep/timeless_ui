defmodule TimelessUI.Poller.Collectors.HttpHealthCollector do
  @moduledoc """
  Checks an HTTP endpoint and emits status, success, and request duration.

  `kind=health` is for a dedicated readiness endpoint; `kind=reachability` is
  for a page or login redirect that only proves the web process answers.
  """

  @behaviour TimelessUI.Poller.Collector

  @impl true
  def init(_config), do: :ok

  @impl true
  def validate_config(config) when is_map(config) do
    path = value(config, "path")
    port = value(config, "port")
    kind = value(config, "kind", "health")
    expected = value(config, "expected_status", 200)
    scheme = value(config, "scheme", "http")

    cond do
      not is_binary(path) or not String.starts_with?(path, "/") ->
        {:error, "path must begin with /"}

      not is_integer(port) or port < 1 or port > 65_535 ->
        {:error, "port must be a valid integer"}

      kind not in ["health", "reachability"] ->
        {:error, "kind must be health or reachability"}

      scheme not in ["http", "https"] ->
        {:error, "scheme must be http or https"}

      not is_integer(expected) or expected < 100 or expected > 599 ->
        {:error, "expected_status must be an HTTP status"}

      true ->
        :ok
    end
  end

  def validate_config(_), do: {:error, "config must be a map"}

  @impl true
  def execute(host, _request, config, opts \\ []) do
    case validate_config(config) do
      :ok -> probe(host, config, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp probe(host, config, opts) do
    scheme = value(config, "scheme", "http")
    url = "#{scheme}://#{host.ip || host.name}:#{value(config, "port")}#{value(config, "path")}"
    fetcher = Keyword.get(opts, :fetcher, &Req.get/2)
    now = System.monotonic_time(:millisecond)
    ts = System.system_time(:second)

    result =
      fetcher.(url,
        redirect: false,
        connect_options: [timeout: 5_000],
        receive_timeout: 5_000
      )

    duration = System.monotonic_time(:millisecond) - now

    labels = %{
      "kind" => value(config, "kind", "health"),
      "service" => value(config, "service", host.name)
    }

    status =
      case result do
        {:ok, %{status: code}} when is_integer(code) -> code
        _ -> 0
      end

    success = if status == value(config, "expected_status", 200), do: 1, else: 0

    {:ok,
     [
       metric("http_probe_success", host.name, success, ts, labels),
       metric("http_probe_status_code", host.name, status, ts, labels),
       metric("http_probe_duration_milliseconds", host.name, duration, ts, labels)
     ]}
  rescue
    _ ->
      ts = System.system_time(:second)

      labels = %{
        "kind" => value(config, "kind", "health"),
        "service" => value(config, "service", host.name)
      }

      {:ok, [metric("http_probe_success", host.name, 0, ts, labels)]}
  end

  defp metric(name, host, val, ts, labels) do
    %{name: name, host: host, type: "http_health", val: val, ts: ts, labels: labels}
  end

  defp value(config, key, default \\ nil),
    do: Map.get(config, key, Map.get(config, String.to_atom(key), default))
end
