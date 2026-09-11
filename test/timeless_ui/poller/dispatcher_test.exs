defmodule TimelessUI.Poller.DispatcherTest do
  use ExUnit.Case, async: false

  alias TimelessUI.Poller.Dispatcher

  test "bounds jittered work before it consumes task slots" do
    start_supervised!({Task.Supervisor, name: TimelessUI.Poller.TaskSupervisor})

    start_supervised!({Dispatcher, max_concurrency: 1, max_queue: 2, jitter_ms: 60_000})

    jobs = for id <- 1..3, do: %{id: id}

    assert %{accepted: 2, dropped: 1} = Dispatcher.enqueue_many(jobs)

    assert %{
             running: 0,
             queued: 2,
             max_queue: 2,
             total_dispatched: 0,
             total_dropped: 1
           } = Dispatcher.stats()
  end
end
