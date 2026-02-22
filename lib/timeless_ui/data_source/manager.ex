defmodule TimelessUI.DataSource.Manager do
  @moduledoc """
  GenServer that manages the active data source module and polls element statuses.

  - Holds the active data source module + its state
  - Polls `status/2` for each tracked element on a configurable interval
  - Broadcasts status changes via `Phoenix.PubSub` on topic `"timeless_ui:status"`
  - Message format: `{:element_status, element_id, status}`
  - Delegates `statuses_at/2` and `time_range/1` to the data source for time travel

  Configuration via application env:

      config :timeless_ui, :data_source,
        module: TimelessUI.DataSource.Stub,
        config: %{},
        poll_interval: 10_000
  """

  use GenServer

  @default_module TimelessUI.DataSource.Stub
  @default_poll_interval 10_000
  @pubsub_topic "timeless_ui:status"
  @metric_topic "timeless_ui:metrics"

  def topic, do: @pubsub_topic
  def metric_topic, do: @metric_topic

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  Register elements for status tracking. Subscribes the data source to each element.
  """
  def register_elements(elements, server \\ __MODULE__) when is_list(elements) do
    GenServer.cast(server, {:register_elements, elements})
  end

  @doc """
  Unregister an element from status tracking.
  """
  def unregister_element(element_id, server \\ __MODULE__) do
    GenServer.cast(server, {:unregister_element, element_id})
  end

  @doc """
  Return the status of each tracked element at the given time.
  Delegates to the data source's `status_at/3`.
  """
  def statuses_at(time, server \\ __MODULE__) do
    GenServer.call(server, {:statuses_at, time})
  end

  @doc """
  Return a metric value for a given element at a specific time.
  Delegates to the data source's `metric_at/4`.
  """
  def metric_at(element_id, metric_name, time, server \\ __MODULE__) do
    GenServer.call(server, {:metric_at, element_id, metric_name, time})
  end

  @doc """
  Return all metric points for an element in a time range.
  Returns `{:ok, [{timestamp_ms, value}, ...]}` or `:no_data`.
  """
  def metric_range(element_id, metric_name, from, to, server \\ __MODULE__) do
    GenServer.call(server, {:metric_range, element_id, metric_name, from, to}, 30_000)
  end

  @doc """
  Return the available time range from the data source, or `:empty`.
  """
  def time_range(server \\ __MODULE__) do
    GenServer.call(server, :time_range)
  end

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    ds_config = Application.get_env(:timeless_ui, :data_source, [])
    module = Keyword.get(ds_config, :module, opts[:module] || @default_module)
    config = Keyword.get(ds_config, :config, opts[:config] || %{})

    poll_interval =
      Keyword.get(ds_config, :poll_interval, opts[:poll_interval] || @default_poll_interval)

    case module.init(config) do
      {:ok, ds_state} ->
        state = %{
          module: module,
          ds_state: ds_state,
          elements: %{},
          poll_interval: poll_interval,
          last_statuses: %{}
        }

        schedule_poll(poll_interval)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:register_elements, elements}, state) do
    {ds_state, element_map} =
      Enum.reduce(elements, {state.ds_state, state.elements}, fn element, {ds, elmap} ->
        {:ok, ds} = state.module.subscribe(ds, element)
        {ds, Map.put(elmap, element.id, element)}
      end)

    {:noreply, %{state | ds_state: ds_state, elements: element_map}}
  end

  def handle_cast({:unregister_element, element_id}, state) do
    case Map.pop(state.elements, element_id) do
      {nil, _elements} ->
        {:noreply, state}

      {element, elements} ->
        {:ok, ds_state} = state.module.unsubscribe(state.ds_state, element)
        last_statuses = Map.delete(state.last_statuses, element_id)

        {:noreply,
         %{state | ds_state: ds_state, elements: elements, last_statuses: last_statuses}}
    end
  end

  @impl true
  def handle_call({:statuses_at, time}, _from, state) do
    statuses =
      Enum.reduce(state.elements, %{}, fn {id, element}, acc ->
        Map.put(acc, id, state.module.status_at(state.ds_state, element, time))
      end)

    {:reply, statuses, state}
  end

  def handle_call({:metric_at, element_id, metric_name, time}, _from, state) do
    result =
      case Map.get(state.elements, element_id) do
        nil -> :no_data
        element -> state.module.metric_at(state.ds_state, element, metric_name, time)
      end

    {:reply, result, state}
  end

  def handle_call({:metric_range, element_id, metric_name, from, to}, _from, state) do
    result =
      case Map.get(state.elements, element_id) do
        nil -> {:ok, []}
        element -> state.module.metric_range(state.ds_state, element, metric_name, from, to)
      end

    {:reply, result, state}
  end

  def handle_call(:time_range, _from, state) do
    {:reply, state.module.time_range(state.ds_state), state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = poll_all(state)
    schedule_poll(state.poll_interval)
    {:noreply, state}
  end

  def handle_info(message, state) do
    case state.module.handle_message(state.ds_state, message) do
      {:status, element_id, status} ->
        state = maybe_broadcast_status(state, element_id, status)
        {:noreply, state}

      {:metric, _element_id, _metric_name, _value} ->
        {:noreply, state}

      :ignore ->
        {:noreply, state}
    end
  end

  # --- Private ---

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end

  defp poll_all(state) do
    Enum.reduce(state.elements, state, fn {element_id, element}, acc ->
      acc = maybe_broadcast_status(acc, element_id, state.module.status(state.ds_state, element))

      if element.type == :graph do
        poll_metric(state, element_id, element)
      end

      acc
    end)
  end

  defp poll_metric(state, element_id, element) do
    metric_name = Map.get(element.meta, "metric_name", "default")

    case state.module.metric(state.ds_state, element, metric_name) do
      {:ok, value} ->
        timestamp = System.system_time(:millisecond)

        Phoenix.PubSub.broadcast(
          TimelessUI.PubSub,
          @metric_topic,
          {:element_metric, element_id, metric_name, value, timestamp}
        )

      :no_data ->
        :ok
    end
  end

  defp maybe_broadcast_status(state, element_id, status) do
    if Map.get(state.last_statuses, element_id) != status do
      Phoenix.PubSub.broadcast(
        TimelessUI.PubSub,
        @pubsub_topic,
        {:element_status, element_id, status}
      )

      %{state | last_statuses: Map.put(state.last_statuses, element_id, status)}
    else
      state
    end
  end
end
