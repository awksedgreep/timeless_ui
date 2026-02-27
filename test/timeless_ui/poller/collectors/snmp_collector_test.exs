defmodule TimelessUI.Poller.Collectors.SnmpCollectorTest do
  use TimelessUI.DataCase, async: false

  alias TimelessUI.Poller.Collectors.SnmpCollector

  import TimelessUI.SnmpFixtures

  # ifXTable base OID
  @base "1.3.6.1.2.1.31.1.1.1"

  # Manual OID map for the simulator: 2 interfaces worth of ifXTable data
  @ifx_oid_map %{
    # ifName
    "#{@base}.1.1" => "eth0",
    "#{@base}.1.2" => "eth1",
    # ifHCInOctets
    "#{@base}.6.1" => %{type: "counter64", value: 123_456_789},
    "#{@base}.6.2" => %{type: "counter64", value: 456_789},
    # ifHCOutOctets
    "#{@base}.10.1" => %{type: "counter64", value: 987_654_321},
    "#{@base}.10.2" => %{type: "counter64", value: 789_123},
    # ifHighSpeed
    "#{@base}.15.1" => %{type: "gauge32", value: 10_000},
    "#{@base}.15.2" => %{type: "gauge32", value: 1_000},
    # ifAlias
    "#{@base}.18.1" => "uplink",
    "#{@base}.18.2" => "lan"
  }

  defp start_simulator(oid_map) do
    {:ok, profile} =
      SnmpKit.SnmpSim.ProfileLoader.load_profile(:generic, {:manual, oid_map})

    # Use a random high port to avoid conflicts
    port = Enum.random(30_000..40_000)

    {:ok, device} = SnmpKit.Sim.start_device(profile, port: port)
    {device, port}
  end

  defp stop_simulator(device) do
    SnmpKit.SnmpSim.Device.stop(device)
  end

  defp make_host(port) do
    %TimelessUI.Poller.Host{
      name: "test-host",
      ip: "127.0.0.1",
      config: %{"port" => port}
    }
  end

  defp make_request(type \\ "snmpbulkwalk") do
    %TimelessUI.Poller.Request{
      name: "test-request",
      type: type,
      config: %{}
    }
  end

  describe "validate_config" do
    setup do
      seed_ifx_table()
      :ok
    end

    test "accepts table mode config when table exists in DB" do
      assert :ok = SnmpCollector.validate_config(%{"table" => "ifXTable"})
    end

    test "rejects table mode config when table doesn't exist" do
      assert {:error, msg} = SnmpCollector.validate_config(%{"table" => "noSuchTable"})
      assert msg =~ "unknown SNMP table"
    end

    test "accepts raw OID mode config" do
      config = %{
        "oids" => [%{"oid" => "1.3.6.1.2.1.1.1.0", "name" => "sysDescr"}]
      }

      assert :ok = SnmpCollector.validate_config(config)
    end

    test "rejects empty config" do
      assert {:error, _} = SnmpCollector.validate_config(%{})
    end

    test "rejects config with neither table nor oids" do
      assert {:error, msg} = SnmpCollector.validate_config(%{"community" => "public"})
      assert msg =~ "table"
    end
  end

  describe "execute table mode" do
    setup do
      seed_ifx_table()
      {device, port} = start_simulator(@ifx_oid_map)
      on_exit(fn -> stop_simulator(device) end)
      %{port: port}
    end

    test "returns metrics from table walk", %{port: port} do
      host = make_host(port)
      request = make_request()

      config = %{
        "table" => "ifXTable",
        "community" => "public",
        "port" => port,
        "timeout" => 5_000
      }

      assert {:ok, metrics} = SnmpCollector.execute(host, request, config)
      assert is_list(metrics)
      assert length(metrics) > 0

      # Each metric should have the required keys
      for metric <- metrics do
        assert Map.has_key?(metric, :name)
        assert Map.has_key?(metric, :host)
        assert Map.has_key?(metric, :type)
        assert Map.has_key?(metric, :labels)
        assert Map.has_key?(metric, :val)
        assert Map.has_key?(metric, :ts)
      end
    end

    test "metric names match metric columns", %{port: port} do
      host = make_host(port)
      request = make_request()

      config = %{
        "table" => "ifXTable",
        "community" => "public",
        "port" => port,
        "timeout" => 5_000
      }

      {:ok, metrics} = SnmpCollector.execute(host, request, config)
      metric_names = metrics |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.sort()

      # The simulator has counter64 and gauge columns — those are metric columns
      # ifName and ifAlias are label columns, so they should NOT appear as metric names
      assert "ifHCInOctets" in metric_names
      assert "ifHCOutOctets" in metric_names
      assert "ifHighSpeed" in metric_names
      refute "ifName" in metric_names
      refute "ifAlias" in metric_names
    end

    test "labels include index and label column values", %{port: port} do
      host = make_host(port)
      request = make_request()

      config = %{
        "table" => "ifXTable",
        "community" => "public",
        "port" => port,
        "timeout" => 5_000
      }

      {:ok, metrics} = SnmpCollector.execute(host, request, config)

      # Find a metric for interface 1
      eth0_metric = Enum.find(metrics, fn m -> m.labels["ifName"] == "eth0" end)
      assert eth0_metric, "Expected a metric with ifName=eth0"

      # Index value should be present as a label
      assert eth0_metric.labels["ifIndex"]
      assert eth0_metric.labels["host"] == "test-host"
      assert eth0_metric.labels["ifAlias"] == "uplink"
    end

    test "metric vals are floats", %{port: port} do
      host = make_host(port)
      request = make_request()

      config = %{
        "table" => "ifXTable",
        "community" => "public",
        "port" => port,
        "timeout" => 5_000
      }

      {:ok, metrics} = SnmpCollector.execute(host, request, config)

      for metric <- metrics do
        assert is_float(metric.val), "Expected float val, got: #{inspect(metric.val)}"
      end
    end
  end

  describe "execute raw OID mode" do
    setup do
      oid_map = %{
        "1.3.6.1.2.1.2.2.1.10.1" => %{type: "counter32", value: 100_000},
        "1.3.6.1.2.1.2.2.1.10.2" => %{type: "counter32", value: 200_000}
      }

      {device, port} = start_simulator(oid_map)
      on_exit(fn -> stop_simulator(device) end)
      %{port: port}
    end

    test "returns metrics from raw OID walk", %{port: port} do
      host = make_host(port)
      request = make_request("snmpwalk")

      config = %{
        "community" => "public",
        "port" => port,
        "timeout" => 5_000,
        "oids" => [%{"oid" => "1.3.6.1.2.1.2.2.1.10"}]
      }

      assert {:ok, metrics} = SnmpCollector.execute(host, request, config)
      assert is_list(metrics)
      assert length(metrics) > 0

      for metric <- metrics do
        assert is_float(metric.val)
        assert metric.host == "test-host"
      end
    end
  end
end
