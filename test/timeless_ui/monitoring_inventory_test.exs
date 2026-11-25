defmodule TimelessUI.MonitoringInventoryTest do
  use TimelessUI.DataCase

  alias TimelessUI.{MonitoringInventory, PrometheusTarget, PrometheusTargets, Repo}
  alias TimelessUI.Poller.{Host, Request, Schedule}

  test "repeated import is idempotent and an address change updates the owned target" do
    manifest = %{
      "scrape_targets" => [
        %{
          "job_name" => "pmon-node-pchr1",
          "address" => "10.200.30.2:9100",
          "labels" => %{"managed_by" => "ddinfra-pmon", "host" => "pchr1"}
        }
      ],
      "poller_hosts" => [%{"name" => "pchr1", "ip" => "10.200.30.2", "tags" => "pmon,chr"}],
      "poller_requests" => [
        %{
          "name" => "pmon-chr-rest",
          "type" => "mikrotik_rest",
          "tags" => "pmon,chr",
          "config" => %{
            "profile" => "core_chr",
            "username" => "pmon",
            "password_env" => "PMON_ROUTEROS_PASSWORD"
          }
        }
      ],
      "poller_schedules" => [
        %{
          "name" => "pmon-chr-minute",
          "cron" => "* * * * *",
          "host_tags" => "pmon,chr",
          "request_tags" => "pmon,chr",
          "enabled" => true
        }
      ]
    }

    assert %{scrape_targets: 1, poller_hosts: 1, poller_requests: 1, poller_schedules: 1} =
             MonitoringInventory.apply!(manifest, sync: false)

    version = PrometheusTargets.version()

    assert %{scrape_targets: 0, poller_hosts: 0, poller_requests: 0, poller_schedules: 0} =
             MonitoringInventory.apply!(manifest, sync: false)

    assert PrometheusTargets.version() == version
    assert Repo.aggregate(PrometheusTarget, :count) == 1
    assert Repo.aggregate(Host, :count) == 1
    assert Repo.aggregate(Request, :count) == 1
    assert Repo.aggregate(Schedule, :count) == 1

    assert Repo.get_by(Request, name: "pmon-chr-rest").config["password_env"] ==
             "PMON_ROUTEROS_PASSWORD"

    updated = put_in(manifest, ["scrape_targets", Access.at(0), "address"], "10.200.30.3:9100")
    assert %{scrape_targets: 1} = MonitoringInventory.apply!(updated, sync: false)
    assert PrometheusTargets.version() == version + 1

    assert Repo.get_by(PrometheusTarget, job_name: "pmon-node-pchr1").address ==
             "10.200.30.3:9100"
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
      MonitoringInventory.apply!(manifest, sync: false)
    end

    assert Repo.aggregate(Request, :count) == 0
  end
end
