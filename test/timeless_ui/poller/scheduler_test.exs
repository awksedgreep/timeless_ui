defmodule TimelessUI.Poller.SchedulerTest do
  use TimelessUI.DataCase, async: false

  alias TimelessUI.Poller.{Dispatcher, Hosts, Requests, Schedule, Scheduler, Schedules}

  test "reuses compiled cron expressions until a schedule changes" do
    now = ~U[2026-09-11 12:00:00Z]
    schedule = %Schedule{id: 1, cron: "* * * * *", enabled: true}

    assert {[^schedule], cache} = Scheduler.due_schedules([schedule], now, %{})
    assert {[^schedule], ^cache} = Scheduler.due_schedules([schedule], now, cache)

    changed = %{schedule | cron: "1 * * * *"}
    assert {[], changed_cache} = Scheduler.due_schedules([changed], now, cache)
    refute changed_cache == cache
  end

  test "caps each tick and records every omitted Cartesian-product job" do
    for id <- 1..2 do
      assert {:ok, _host} = Hosts.create_host(%{name: "host-#{id}", ip: "127.0.0.#{id}"})

      assert {:ok, _request} =
               Requests.create_request(%{name: "request-#{id}", type: "icmp_ping"})
    end

    assert {:ok, _schedule} =
             Schedules.create_schedule(%{name: "every-minute", cron: "* * * * *", enabled: true})

    start_supervised!({Dispatcher, max_queue: 10, jitter_ms: 60_000})
    scheduler = start_supervised!({Scheduler, max_jobs_per_tick: 3})

    send(scheduler, :tick)
    _ = :sys.get_state(scheduler)

    assert %{jobs_enqueued: 3, jobs_dropped: 1} = Scheduler.stats()
    assert %{queued: 3, total_dropped: 0} = Dispatcher.stats()
  end
end
