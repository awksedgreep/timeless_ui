defmodule TimelessUI.OperationsMonitor do
  @moduledoc """
  Subscriber-driven polling for operational LiveViews.

  One process polls each source and broadcasts only changed snapshots, so the
  amount of control-plane work does not grow with the number of browser tabs.
  """

  use GenServer

  alias TimelessUI.MetricsAPI
  alias TimelessUI.Poller.{Dispatcher, Scheduler}

  @intervals %{poller_stats: 15_000, scrape_targets: 15_000}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def subscribe(kind) when is_map_key(@intervals, kind) do
    Phoenix.PubSub.subscribe(TimelessUI.PubSub, topic(kind))
    GenServer.call(__MODULE__, {:subscribe, kind, self()})
  end

  def snapshot(kind) when is_map_key(@intervals, kind),
    do: GenServer.call(__MODULE__, {:snapshot, kind})

  def refresh(kind) when is_map_key(@intervals, kind),
    do: GenServer.call(__MODULE__, {:refresh, kind})

  @impl true
  def init(_opts) do
    {:ok, %{values: %{}, subscribers: %{}, timers: %{}}}
  end

  @impl true
  def handle_call({:subscribe, kind, pid}, _from, state) do
    state = add_subscriber(state, kind, pid)
    {value, state} = ensure_value(state, kind)
    {:reply, value, schedule(state, kind)}
  end

  def handle_call({:snapshot, kind}, _from, state) do
    {value, state} = ensure_value(state, kind)
    {:reply, value, state}
  end

  def handle_call({:refresh, kind}, _from, state) do
    {value, state} = reload(state, kind)
    {:reply, value, state}
  end

  @impl true
  def handle_info({:poll, kind}, state) do
    state = %{state | timers: Map.delete(state.timers, kind)}
    {_value, state} = reload(state, kind)
    {:noreply, schedule(state, kind)}
  end

  def handle_info({:DOWN, reference, :process, pid, _reason}, state) do
    state =
      case Map.get(state.subscribers, pid) do
        %{ref: ^reference} -> %{state | subscribers: Map.delete(state.subscribers, pid)}
        _ -> state
      end

    {:noreply, state}
  end

  defp add_subscriber(state, kind, pid) do
    case Map.get(state.subscribers, pid) do
      nil ->
        ref = Process.monitor(pid)
        put_in(state.subscribers[pid], %{ref: ref, kinds: MapSet.new([kind])})

      subscriber ->
        put_in(state.subscribers[pid].kinds, MapSet.put(subscriber.kinds, kind))
    end
  end

  defp ensure_value(state, kind) do
    case Map.fetch(state.values, kind) do
      {:ok, value} -> {value, state}
      :error -> reload(state, kind)
    end
  end

  defp reload(state, kind) do
    value = load(kind)

    if match?({:ok, previous} when previous != value, Map.fetch(state.values, kind)) do
      Phoenix.PubSub.broadcast(TimelessUI.PubSub, topic(kind), {:operations_update, kind, value})
    end

    {value, put_in(state.values[kind], value)}
  end

  defp load(:poller_stats) do
    %{
      scheduler:
        safe_call(fn -> Scheduler.stats() end, %{
          schedules_total: 0,
          last_tick: nil,
          jobs_enqueued: 0,
          jobs_dropped: 0
        }),
      dispatcher:
        safe_call(fn -> Dispatcher.stats() end, %{
          running: 0,
          queued: 0,
          max_concurrency: 0,
          max_queue: 0,
          total_dispatched: 0,
          total_dropped: 0
        })
    }
  end

  defp load(:scrape_targets),
    do: safe_call(fn -> MetricsAPI.list_targets() end, {:error, :metrics_scraper_unavailable})

  defp schedule(state, kind) do
    cond do
      Map.has_key?(state.timers, kind) ->
        state

      subscribed?(state, kind) ->
        timer = Process.send_after(self(), {:poll, kind}, Map.fetch!(@intervals, kind))
        put_in(state.timers[kind], timer)

      true ->
        state
    end
  end

  defp subscribed?(state, kind) do
    Enum.any?(state.subscribers, fn {_pid, subscriber} ->
      MapSet.member?(subscriber.kinds, kind)
    end)
  end

  defp safe_call(operation, default) do
    operation.()
  rescue
    _error -> default
  catch
    :exit, _reason -> default
  end

  defp topic(kind), do: "operations:#{kind}"
end
