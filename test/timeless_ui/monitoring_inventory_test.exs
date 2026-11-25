defmodule TimelessUI.MonitoringInventoryTest do
  use TimelessUI.DataCase

  alias TimelessUI.{MonitoringInventory, PrometheusTarget, PrometheusTargets, Repo}
  alias TimelessUI.Poller.{Host, Request, Schedule}

  test "repeated import is idempotent and an address change updates the owned target" do
    manifest = %{
      "scrape_targets" => [
        %{
          "job_name" => "ops-node-router-a",
          "address" => "192.0.2.2:9100",
          "labels" => %{"managed_by" => "ops-monitor", "host" => "router-a"}
        }
      ],
      "poller_hosts" => [%{"name" => "router-a", "ip" => "192.0.2.2", "tags" => "ops,routeros"}],
      "poller_requests" => [
        %{
          "name" => "ops-routeros-rest",
          "type" => "mikrotik_rest",
          "tags" => "ops,routeros",
          "config" => %{
            "profile" => "routeros_inventory",
            "username" => "monitor",
            "password_env" => "ROUTEROS_PASSWORD"
          }
        }
      ],
      "poller_schedules" => [
        %{
          "name" => "ops-routeros-minute",
          "cron" => "* * * * *",
          "host_tags" => "ops,routeros",
          "request_tags" => "ops,routeros",
          "enabled" => true
        }
      ]
    }

    assert %{scrape_targets: 1, poller_hosts: 1, poller_requests: 1, poller_schedules: 1} =
             MonitoringInventory.apply!(manifest, managed_by: "ops-monitor", sync: false)

    version = PrometheusTargets.version()

    assert %{scrape_targets: 0, poller_hosts: 0, poller_requests: 0, poller_schedules: 0} =
             MonitoringInventory.apply!(manifest, sync: false)

    assert PrometheusTargets.version() == version
    assert Repo.aggregate(PrometheusTarget, :count) == 1
    assert Repo.aggregate(Host, :count) == 1
    assert Repo.aggregate(Request, :count) == 1
    assert Repo.aggregate(Schedule, :count) == 1

    assert Repo.get_by(Request, name: "ops-routeros-rest").config["password_env"] ==
             "ROUTEROS_PASSWORD"

    updated = put_in(manifest, ["scrape_targets", Access.at(0), "address"], "192.0.2.3:9100")

    assert %{scrape_targets: 1} =
             MonitoringInventory.apply!(updated, managed_by: "ops-monitor", sync: false)

    assert PrometheusTargets.version() == version + 1

    assert Repo.get_by(PrometheusTarget, job_name: "ops-node-router-a").address ==
             "192.0.2.3:9100"
  end

  test "refuses inline credentials before writing any records" do
    manifest = %{
      "scrape_targets" => [],
      "poller_hosts" => [],
      "poller_requests" => [
        %{"name" => "bad", "type" => "mikrotik_rest", "config" => %{"password" => "x"}}
      ],
      "poller_schedules" => []
    }

    assert_raise ArgumentError, ~r/credentials/, fn ->
      MonitoringInventory.apply!(manifest, managed_by: "ops-monitor", sync: false)
    end

    assert Repo.aggregate(Request, :count) == 0
  end

  test "requires the caller's ownership label before importing targets" do
    manifest = %{
      "scrape_targets" => [
        %{
          "job_name" => "ops-node-router-a",
          "address" => "192.0.2.2:9100",
          "labels" => %{"managed_by" => "another-monitor"}
        }
      ],
      "poller_hosts" => [],
      "poller_requests" => [],
      "poller_schedules" => []
    }

    assert_raise ArgumentError, ~r/ownership label/, fn ->
      MonitoringInventory.apply!(manifest, managed_by: "ops-monitor", sync: false)
    end

    assert Repo.aggregate(PrometheusTarget, :count) == 0
  end
end
