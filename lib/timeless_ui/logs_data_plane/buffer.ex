defmodule TimelessUI.LogsDataPlane.Buffer do
  @moduledoc """
  Bounded, non-blocking transport buffer for Logger events sent to the Rust
  logs process. HTTP flushes run in supervised tasks and failures are retried
  with backoff, so application Logger callers never wait on the data plane.
  """

  use GenServer

  alias TimelessUI.LogsDataPlane.Client
  alias TimelessUI.LogsDataPlane.LoggerHandler

  @transport_batch_size 256
  @default_flush_interval 1_000
  @maximum_backoff 30_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def log(server \\ __MODULE__, entry) do
    case GenServer.whereis(server) do
      nil -> {:error, :logs_transport_unavailable}
      _pid -> GenServer.cast(server, {:log, entry})
    end
  end

  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush, 30_000)
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      entries: [],
      count: 0,
      max_entries: Keyword.get(opts, :max_entries, @transport_batch_size),
      flush_interval: Keyword.get(opts, :flush_interval, @default_flush_interval),
      client: Keyword.get(opts, :client, Client),
      client_opts: Keyword.get(opts, :client_opts, []),
      in_flight: nil,
      flush_waiters: [],
      retry_at: nil,
      retry_timer: nil,
      consecutive_failures: 0,
      admitted: 0,
      completed: 0,
      dropped: 0,
      failed_flushes: 0,
      last_error: nil,
      install_logger: Keyword.get(opts, :install_logger, true)
    }

    if state.install_logger do
      :ok =
        install_handler(
          Keyword.get(opts, :handler_level, :all),
          Keyword.get(opts, :name, __MODULE__)
        )
    end

    schedule_flush(state.flush_interval)
    {:ok, state}
  end

  @impl true
  def handle_cast({:log, entry}, state) do
    state = accept(state, entry)
    {:noreply, if(state.count >= state.max_entries, do: maybe_start_flush(state), else: state)}
  end

  @impl true
  def handle_call(:flush, _from, %{count: 0, in_flight: nil} = state),
    do: {:reply, :ok, state}

  def handle_call(:flush, from, state) do
    if retry_blocked?(state) and state.in_flight == nil do
      {:reply, {:error, {:flush_backoff, state.last_error}}, state}
    else
      state = %{state | flush_waiters: [from | state.flush_waiters]}
      {:noreply, maybe_start_flush(state)}
    end
  end

  def handle_call(:stats, _from, state) do
    report =
      state
      |> Map.take([
        :count,
        :max_entries,
        :admitted,
        :completed,
        :dropped,
        :failed_flushes,
        :last_error
      ])
      |> Map.put(:flushing, state.in_flight != nil)

    {:reply, report, state}
  end

  @impl true
  def handle_info(:periodic_flush, state) do
    schedule_flush(state.flush_interval)
    {:noreply, maybe_start_flush(state)}
  end

  def handle_info(:retry_flush, state),
    do: {:noreply, maybe_start_flush(%{state | retry_timer: nil})}

  def handle_info({reference, result}, %{in_flight: %{ref: reference}} = state) do
    Process.demonitor(reference, [:flush])

    state =
      case result do
        {:ok, count} when count == state.in_flight.count -> flush_succeeded(state)
        other -> flush_failed(state, {:incomplete_logs_transport_flush, other})
      end

    {:noreply, state}
  end

  def handle_info(
        {:DOWN, reference, :process, _pid, reason},
        %{in_flight: %{ref: reference}} = state
      ) do
    {:noreply, flush_failed(state, {:logs_transport_task_exit, reason})}
  end

  def handle_info({_reference, _result}, state), do: {:noreply, state}
  def handle_info({:DOWN, _reference, :process, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.install_logger, do: :logger.remove_handler(LoggerHandler.handler_id())

    entries =
      case state.in_flight do
        nil -> Enum.reverse(state.entries)
        in_flight -> in_flight.entries ++ Enum.reverse(state.entries)
      end

    if entries != [], do: state.client.ingest(entries, state.client_opts)
    :ok
  end

  defp accept(%{count: count, max_entries: max} = state, entry) when count >= max do
    %{
      state
      | entries: [entry | Enum.take(state.entries, max - 1)],
        admitted: state.admitted + 1,
        dropped: state.dropped + 1
    }
  end

  defp accept(state, entry) do
    %{
      state
      | entries: [entry | state.entries],
        count: state.count + 1,
        admitted: state.admitted + 1
    }
  end

  defp maybe_start_flush(%{in_flight: in_flight} = state) when in_flight != nil, do: state
  defp maybe_start_flush(%{count: 0} = state), do: reply_waiters(state, :ok)

  defp maybe_start_flush(state) do
    if retry_blocked?(state) do
      state
    else
      entries = Enum.reverse(state.entries)
      client = state.client
      client_opts = state.client_opts

      task =
        Task.Supervisor.async_nolink(TimelessUI.TaskSupervisor, fn ->
          client.ingest(entries, client_opts)
        end)

      %{
        state
        | entries: [],
          count: 0,
          in_flight: %{ref: task.ref, pid: task.pid, entries: entries, count: length(entries)}
      }
    end
  end

  defp flush_succeeded(state) do
    state = %{
      state
      | in_flight: nil,
        completed: state.completed + state.in_flight.count,
        consecutive_failures: 0,
        retry_at: nil,
        last_error: nil
    }

    if state.flush_waiters == [] do
      state
    else
      state |> maybe_start_flush() |> maybe_finish_waiters()
    end
  end

  defp flush_failed(state, reason) do
    chronological = state.in_flight.entries ++ Enum.reverse(state.entries)
    retained = Enum.take(chronological, -state.max_entries)
    dropped = length(chronological) - length(retained)
    failures = state.consecutive_failures + 1
    backoff = min(1_000 * Integer.pow(2, min(failures - 1, 5)), @maximum_backoff)
    retry_timer = Process.send_after(self(), :retry_flush, backoff)

    :telemetry.execute(
      [:timeless_ui, :logs_data_plane, :flush, :error],
      %{entries: state.in_flight.count},
      %{reason: reason}
    )

    state
    |> Map.merge(%{
      entries: Enum.reverse(retained),
      count: length(retained),
      in_flight: nil,
      retry_at: System.monotonic_time(:millisecond) + backoff,
      retry_timer: retry_timer,
      consecutive_failures: failures,
      dropped: state.dropped + dropped,
      failed_flushes: state.failed_flushes + 1,
      last_error: inspect(reason)
    })
    |> reply_waiters({:error, reason})
  end

  defp maybe_finish_waiters(%{in_flight: nil, count: 0} = state),
    do: reply_waiters(state, :ok)

  defp maybe_finish_waiters(state), do: state

  defp reply_waiters(state, reply) do
    Enum.each(state.flush_waiters, &GenServer.reply(&1, reply))
    %{state | flush_waiters: []}
  end

  defp retry_blocked?(%{retry_at: nil}), do: false
  defp retry_blocked?(state), do: System.monotonic_time(:millisecond) < state.retry_at

  defp install_handler(level, buffer) do
    config = %{level: level, config: %{buffer: buffer}}

    case :logger.add_handler(LoggerHandler.handler_id(), LoggerHandler, config) do
      :ok ->
        :ok

      {:error, {:already_exist, _id}} ->
        :logger.set_handler_config(LoggerHandler.handler_id(), config)

      {:error, reason} ->
        raise "cannot install logs data-plane Logger handler: #{inspect(reason)}"
    end
  end

  defp schedule_flush(interval), do: Process.send_after(self(), :periodic_flush, interval)
end
