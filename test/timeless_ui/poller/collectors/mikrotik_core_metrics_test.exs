defmodule TimelessUI.Poller.Collectors.MikrotikCoreMetricsTest do
  use ExUnit.Case, async: true

  alias TimelessUI.Poller.Collectors.{MikrotikCoreMetrics, MikrotikRestCollector}

  @host %{name: "pchr1", ip: "10.200.30.2"}
  @config %{
    "profile" => "core_chr",
    "username" => "pmon",
    "password_env" => "PMON_ROUTEROS_PASSWORD",
    "port" => 80,
    "ssl" => false
  }

  defmodule Client do
    def get(_auth, _ip, path, _opts) do
      {:ok,
       case path do
         "/system/resource" ->
           %{
             "cpu-load" => "12",
             "free-memory" => "1000",
             "total-memory" => "2000",
             "free-hdd-space" => "300",
             "total-hdd-space" => "400",
             "uptime" => "1w2d3h4m5s",
             "version" => "7.24.2",
             "board-name" => "CHR"
           }

         "/system/health" ->
           %{"state" => "disabled"}

         "/interface" ->
           [
             %{
               "name" => "tun1",
               "type" => "gre-tunnel",
               "running" => "true",
               "disabled" => "false",
               "rx-byte" => "123",
               "tx-byte" => "456"
             },
             %{
               "name" => "tun2",
               "type" => "gre-tunnel",
               "running" => "false",
               "disabled" => "false",
               "rx-byte" => "0",
               "tx-byte" => "0"
             },
             %{
               "name" => "wgdiablo",
               "type" => "wg",
               "running" => "true",
               "disabled" => "false",
               "rx-byte" => "25",
               "tx-byte" => "30"
             },
             %{
               "name" => "future-ipip",
               "type" => "ipip-tunnel",
               "running" => "true",
               "disabled" => "false"
             }
           ]

         "/interface/gre" ->
           [
             %{"name" => "tun1", "running" => "true", "disabled" => "false"},
             %{"name" => "tun2", "running" => "false", "disabled" => "false"}
           ]

         "/interface/wireguard" ->
           [%{"name" => "wgdiablo", "running" => "true", "disabled" => "false"}]

         "/interface/wireguard/peers" ->
           [
             %{
               "name" => "peer1",
               "interface" => "wgdiablo",
               "disabled" => "false",
               "rx" => "100",
               "tx" => "200",
               "last-handshake" => "1m2s",
               "public-key" => "not-a-label",
               "current-endpoint-address" => "192.0.2.10"
             },
             %{
               "name" => "peer2",
               "interface" => "wgdiablo",
               "disabled" => "false",
               "rx" => "0",
               "tx" => "0"
             }
           ]

         "/interface/vrrp" ->
           [%{"name" => "vrrp1", "running" => "true", "master" => "true"}]
       end}
    end
  end

  defmodule PeerFailureClient do
    def get(_auth, _ip, "/interface/wireguard/peers", _opts), do: {:error, %{status: 401}}
    def get(auth, ip, path, opts), do: Client.get(auth, ip, path, opts)
  end

  defmodule MalformedClient do
    def get(_auth, _ip, "/interface/gre", _opts), do: {:ok, [%{"name" => "tun1"}, "bad row"]}
    def get(auth, ip, path, opts), do: Client.get(auth, ip, path, opts)
  end

  test "collects every tunnel, peer, counter, and role without secret labels" do
    assert :ok = MikrotikCoreMetrics.validate_config(@config)
    assert :ok = MikrotikRestCollector.validate_config(@config)

    assert {:ok, metrics} =
             MikrotikRestCollector.execute(@host, nil, @config,
               client: Client,
               password_provider: fn _ -> "vault-secret" end
             )

    assert value(metrics, "routeros_up") == 1
    assert value(metrics, "routeros_tunnel_count", %{"tunnel_type" => "gre"}) == 2
    assert value(metrics, "routeros_tunnel_count", %{"tunnel_type" => "wireguard"}) == 1
    assert value(metrics, "routeros_wireguard_peer_count") == 2

    assert value(metrics, "routeros_wireguard_peer_handshake_age_seconds", %{"peer" => "peer1"}) ==
             62

    assert value(metrics, "routeros_wireguard_peer_handshake_seen", %{"peer" => "peer2"}) == 0

    assert value(metrics, "routeros_interface_receive_bytes_total", %{"interface" => "tun1"}) ==
             123

    assert value(metrics, "routeros_interface_running", %{"interface" => "future-ipip"}) == 1
    assert value(metrics, "routeros_vrrp_master", %{"instance" => "vrrp1"}) == 1
    assert value(metrics, "routeros_uptime_seconds") == 788_645

    refute Enum.any?(metrics, fn metric ->
             Map.has_key?(metric.labels, "public-key") or
               Map.has_key?(metric.labels, "current-endpoint-address")
           end)
  end

  test "a failed peer request remains visible and marks the router unhealthy" do
    assert {:ok, metrics} =
             MikrotikCoreMetrics.execute(@host, @config,
               client: PeerFailureClient,
               password_provider: fn _ -> "vault-secret" end
             )

    assert value(metrics, "routeros_up") == 0
    assert value(metrics, "routeros_collection_success", %{"resource" => "peer"}) == 0
    assert value(metrics, "routeros_collection_success", %{"resource" => "gre"}) == 1
  end

  test "missing secret and inline secret are rejected" do
    assert {:error, _} =
             MikrotikCoreMetrics.validate_config(Map.put(@config, "password", "secret"))

    assert {:ok, metrics} =
             MikrotikCoreMetrics.execute(@host, @config,
               client: Client,
               password_provider: fn _ -> nil end
             )

    assert value(metrics, "routeros_up") == 0
    assert value(metrics, "routeros_collection_success", %{"resource" => "auth"}) == 0
  end

  test "malformed tunnel data is reported as a failed collection" do
    assert {:ok, metrics} =
             MikrotikCoreMetrics.execute(@host, @config,
               client: MalformedClient,
               password_provider: fn _ -> "vault-secret" end
             )

    assert value(metrics, "routeros_up") == 0
    assert value(metrics, "routeros_collection_success", %{"resource" => "gre"}) == 0
  end

  defp value(metrics, name, labels \\ %{}) do
    metrics
    |> Enum.find(fn metric ->
      metric.name == name and Enum.all?(labels, fn {k, v} -> metric.labels[k] == v end)
    end)
    |> then(& &1.val)
  end
end
