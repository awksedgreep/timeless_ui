defmodule TimelessUI.Poller.Collectors.HttpHealthCollectorTest do
  use ExUnit.Case, async: true

  alias TimelessUI.Poller.Collectors.HttpHealthCollector

  @host %{name: "ddnet@pdhcp1", ip: "192.168.160.220"}
  @config %{
    "path" => "/health/ready",
    "port" => 4000,
    "service" => "ddnet",
    "kind" => "health"
  }

  test "reports a meaningful 200 health response and duration" do
    fetcher = fn url, opts ->
      assert url == "http://192.168.160.220:4000/health/ready"
      assert opts[:redirect] == false
      assert opts[:retry] == false
      {:ok, %{status: 200}}
    end

    assert {:ok, metrics} = HttpHealthCollector.execute(@host, nil, @config, fetcher: fetcher)
    assert metric_value(metrics, "http_probe_success") == 1
    assert metric_value(metrics, "http_probe_status_code") == 200
    assert metric_value(metrics, "http_probe_duration_milliseconds") >= 0
    assert Enum.all?(metrics, &(&1.labels == %{"kind" => "health", "service" => "ddnet"}))
  end

  test "a degraded response and a connection failure are visible" do
    assert {:ok, degraded} =
             HttpHealthCollector.execute(@host, nil, @config,
               fetcher: fn _, _ -> {:ok, %{status: 503}} end
             )

    assert metric_value(degraded, "http_probe_success") == 0
    assert metric_value(degraded, "http_probe_status_code") == 503

    assert {:ok, failed} =
             HttpHealthCollector.execute(@host, nil, @config,
               fetcher: fn _, _ -> {:error, :econnrefused} end
             )

    assert metric_value(failed, "http_probe_success") == 0
    assert metric_value(failed, "http_probe_status_code") == 0
  end

  test "rejects an invalid path and scheme" do
    assert {:error, _} = HttpHealthCollector.validate_config(%{@config | "path" => "ready"})
    assert {:error, _} = HttpHealthCollector.validate_config(Map.put(@config, "scheme", "file"))
  end

  test "uses the pinned internal CA for an HTTPS health probe" do
    config =
      @config
      |> Map.put("scheme", "https")
      |> Map.put("ca_file", "/etc/monitor-ca.pem")

    fetcher = fn url, opts ->
      assert url == "https://192.168.160.220:4000/health/ready"

      assert opts[:connect_options][:transport_opts] ==
               [cacertfile: "/etc/monitor-ca.pem"]

      assert opts[:retry] == false

      {:ok, %{status: 503}}
    end

    assert {:ok, metrics} = HttpHealthCollector.execute(@host, nil, config, fetcher: fetcher)
    assert metric_value(metrics, "http_probe_status_code") == 503
  end

  defp metric_value(metrics, name), do: Enum.find(metrics, &(&1.name == name)).val
end
