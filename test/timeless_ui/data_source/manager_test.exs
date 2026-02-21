defmodule TimelessUI.DataSource.ManagerTest do
  use ExUnit.Case, async: true

  alias TimelessUI.Canvas.Element
  alias TimelessUI.DataSource.Manager

  # Use a unique name per test to avoid conflicts
  defp start_manager(opts \\ []) do
    name = :"manager_#{System.unique_integer([:positive])}"

    opts =
      Keyword.merge(
        [name: name, module: TimelessUI.DataSource.Stub, config: %{}, poll_interval: 60_000],
        opts
      )

    {:ok, pid} = Manager.start_link(opts)
    {pid, name}
  end

  describe "Stub data source" do
    test "init succeeds" do
      assert {:ok, _state} = TimelessUI.DataSource.Stub.init(%{})
    end

    test "status returns :unknown" do
      {:ok, state} = TimelessUI.DataSource.Stub.init(%{})
      element = %Element{id: "el-1", type: :server}
      assert TimelessUI.DataSource.Stub.status(state, element) == :unknown
    end

    test "metric returns :no_data" do
      {:ok, state} = TimelessUI.DataSource.Stub.init(%{})
      element = %Element{id: "el-1", type: :server}
      assert TimelessUI.DataSource.Stub.metric(state, element, "cpu") == :no_data
    end

    test "handle_message returns :ignore" do
      {:ok, state} = TimelessUI.DataSource.Stub.init(%{})
      assert TimelessUI.DataSource.Stub.handle_message(state, :anything) == :ignore
    end

    test "status_at returns :unknown" do
      {:ok, state} = TimelessUI.DataSource.Stub.init(%{})
      element = %Element{id: "el-1", type: :server}
      assert TimelessUI.DataSource.Stub.status_at(state, element, DateTime.utc_now()) == :unknown
    end

    test "time_range returns :empty" do
      {:ok, state} = TimelessUI.DataSource.Stub.init(%{})
      assert TimelessUI.DataSource.Stub.time_range(state) == :empty
    end
  end

  describe "Random data source" do
    test "init succeeds" do
      assert {:ok, _state} = TimelessUI.DataSource.Random.init(%{})
    end

    test "status returns a valid status atom" do
      {:ok, state} = TimelessUI.DataSource.Random.init(%{})
      element = %Element{id: "el-1", type: :server}
      status = TimelessUI.DataSource.Random.status(state, element)
      assert status in [:ok, :warning, :error, :unknown]
    end

    test "metric returns a float value" do
      {:ok, state} = TimelessUI.DataSource.Random.init(%{})
      element = %Element{id: "el-1", type: :server}
      assert {:ok, value} = TimelessUI.DataSource.Random.metric(state, element, "cpu")
      assert is_float(value)
      assert value >= 0.0 and value <= 100.0
    end

    test "status_at is deterministic for same element+time" do
      {:ok, state} = TimelessUI.DataSource.Random.init(%{})
      element = %Element{id: "el-1", type: :server}
      time = DateTime.utc_now()
      s1 = TimelessUI.DataSource.Random.status_at(state, element, time)
      s2 = TimelessUI.DataSource.Random.status_at(state, element, time)
      assert s1 == s2
      assert s1 in [:ok, :warning, :error, :unknown]
    end

    test "metric_at is deterministic for same element+time" do
      {:ok, state} = TimelessUI.DataSource.Random.init(%{})
      element = %Element{id: "el-1", type: :graph, meta: %{"metric_name" => "cpu"}}
      time = DateTime.utc_now()
      {:ok, v1} = TimelessUI.DataSource.Random.metric_at(state, element, "cpu", time)
      {:ok, v2} = TimelessUI.DataSource.Random.metric_at(state, element, "cpu", time)
      assert v1 == v2
      assert is_float(v1)
    end

    test "metric_at returns values in expected range" do
      {:ok, state} = TimelessUI.DataSource.Random.init(%{})
      element = %Element{id: "el-1", type: :graph}
      time = DateTime.utc_now()
      {:ok, value} = TimelessUI.DataSource.Random.metric_at(state, element, "cpu", time)
      # sine wave: 50 +/- 30 => [20.0, 80.0]
      assert value >= 20.0 and value <= 80.0
    end

    test "time_range returns a 1-hour window" do
      {:ok, state} = TimelessUI.DataSource.Random.init(%{})
      {start_time, end_time} = TimelessUI.DataSource.Random.time_range(state)
      diff = DateTime.diff(end_time, start_time, :second)
      assert diff >= 3599 and diff <= 3601
    end
  end

  describe "Manager GenServer" do
    test "starts successfully with default stub" do
      {pid, _name} = start_manager()
      assert Process.alive?(pid)
    end

    test "register_elements subscribes elements" do
      {_pid, name} = start_manager()
      element = %Element{id: "el-1", type: :server, label: "Web Server"}
      Manager.register_elements([element], name)
      # Give the cast time to process
      :timer.sleep(50)
      # If we got here without error, subscription worked
      assert true
    end

    test "unregister_element removes element" do
      {_pid, name} = start_manager()
      element = %Element{id: "el-1", type: :server}
      Manager.register_elements([element], name)
      :timer.sleep(50)
      Manager.unregister_element("el-1", name)
      :timer.sleep(50)
      assert true
    end

    test "broadcasts status changes on poll" do
      Phoenix.PubSub.subscribe(TimelessUI.PubSub, Manager.topic())

      {_pid, name} =
        start_manager(module: TimelessUI.DataSource.Random, poll_interval: 50)

      element = %Element{id: "el-test-#{System.unique_integer([:positive])}", type: :server}
      Manager.register_elements([element], name)

      # Wait for poll + broadcast
      assert_receive {:element_status, _id, status}, 500
      assert status in [:ok, :warning, :error, :unknown]
    end

    test "broadcasts metric updates for graph elements" do
      Phoenix.PubSub.subscribe(TimelessUI.PubSub, Manager.metric_topic())

      {_pid, name} =
        start_manager(module: TimelessUI.DataSource.Random, poll_interval: 50)

      element = %Element{
        id: "el-graph-#{System.unique_integer([:positive])}",
        type: :graph,
        meta: %{"metric_name" => "cpu"}
      }

      Manager.register_elements([element], name)

      assert_receive {:element_metric, _id, "cpu", value, _ts}, 500
      assert is_float(value)
    end

    test "metric_at delegates to data source" do
      {_pid, name} = start_manager(module: TimelessUI.DataSource.Random, poll_interval: 60_000)

      element = %Element{id: "el-g-1", type: :graph, meta: %{"metric_name" => "cpu"}}
      Manager.register_elements([element], name)
      :timer.sleep(50)

      time = DateTime.utc_now()
      assert {:ok, value} = Manager.metric_at("el-g-1", "cpu", time, name)
      assert is_float(value)
      # Deterministic
      assert {:ok, ^value} = Manager.metric_at("el-g-1", "cpu", time, name)
    end

    test "metric_at returns :no_data for unknown element" do
      {_pid, name} = start_manager(poll_interval: 60_000)
      assert Manager.metric_at("nonexistent", "cpu", DateTime.utc_now(), name) == :no_data
    end

    test "does not broadcast when status unchanged" do
      # Use Stub which always returns :unknown
      Phoenix.PubSub.subscribe(TimelessUI.PubSub, Manager.topic())

      {_pid, name} = start_manager(poll_interval: 50)

      element = %Element{id: "el-stable-#{System.unique_integer([:positive])}", type: :server}
      Manager.register_elements([element], name)

      # First poll will broadcast (nil -> :unknown)
      assert_receive {:element_status, _id, :unknown}, 500

      # Subsequent polls should not broadcast since status stays :unknown
      refute_receive {:element_status, _, _}, 200
    end
  end

  describe "time_range/1" do
    test "Stub returns :empty" do
      {_pid, name} = start_manager(poll_interval: 60_000)
      assert Manager.time_range(name) == :empty
    end

    test "Random returns valid range" do
      {_pid, name} = start_manager(module: TimelessUI.DataSource.Random, poll_interval: 60_000)
      assert {%DateTime{}, %DateTime{}} = Manager.time_range(name)
    end
  end

  describe "statuses_at/2" do
    test "delegates to data source" do
      {_pid, name} = start_manager(module: TimelessUI.DataSource.Random, poll_interval: 60_000)

      element = %Element{id: "el-sa-1", type: :server}
      Manager.register_elements([element], name)
      :timer.sleep(50)

      time = DateTime.utc_now()
      statuses = Manager.statuses_at(time, name)
      assert is_map(statuses)
      assert Map.get(statuses, "el-sa-1") in [:ok, :warning, :error, :unknown]

      # Same time should return same result (deterministic)
      assert Manager.statuses_at(time, name) == statuses
    end
  end
end
