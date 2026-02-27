defmodule TimelessUI.Poller.Collectors.IcmpCollector do
  @moduledoc """
  ICMP ping collector. Uses RawPing to measure host reachability and RTT.
  """

  @behaviour TimelessUI.Poller.Collector

  require Logger

  @impl true
  def init(_config), do: :ok

  @impl true
  def validate_config(_config), do: :ok

  @impl true
  def execute(host, _request, _config, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, poller_config(:icmp_timeout_ms, 1_000))
    count = Keyword.get(opts, :count, poller_config(:icmp_count, 1))
    ip = host.ip
    ts = System.system_time(:millisecond)

    case RawPing.ping_stats(ip, count: count, timeout: timeout) do
      {:ok, stats} ->
        labels = build_labels(host)
        success = if stats.received > 0, do: 1, else: 0
        rtt = stats.avg || 0.0

        metrics = [
          %{
            name: "icmp_ping_success",
            host: host.name,
            type: "icmp",
            labels: labels,
            val: success,
            ts: ts
          },
          %{
            name: "icmp_ping_rtt_ms",
            host: host.name,
            type: "icmp",
            labels: labels,
            val: rtt,
            ts: ts
          }
        ]

        {:ok, metrics}

      {:error, reason} ->
        Logger.warning("ICMP ping failed for #{host.name} (#{ip}): #{inspect(reason)}")
        labels = build_labels(host)

        metrics = [
          %{
            name: "icmp_ping_success",
            host: host.name,
            type: "icmp",
            labels: labels,
            val: 0,
            ts: ts
          }
        ]

        {:ok, metrics}
    end
  end

  defp build_labels(host) do
    %{
      "host" => host.name,
      "ip" => host.ip,
      "type" => host.type
    }
  end

  defp poller_config(key, default) do
    config = Application.get_env(:timeless_ui, :poller, [])
    Keyword.get(config, key, default)
  end
end
