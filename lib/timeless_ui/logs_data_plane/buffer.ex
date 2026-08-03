defmodule TimelessUI.LogsDataPlane.Buffer do
  @moduledoc """
  Small bounded transport buffer for Logger events sent to the Rust logs
  process. It is deliberately smaller than the Rust extension's authoritative
  8,192-entry storage batch: this process only protects the BEAM transport and
  never chooses storage block boundaries, compresses, or writes storage.
  """

  use GenServer

  alias TimelessUI.LogsDataPlane.Client
  alias TimelessUI.LogsDataPlane.LoggerHandler

  @transport_batch_size 256
  @default_flush_interval 1_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def log(server \\ __MODULE__, entry), do: GenServer.call(server, {:log, entry}, 30_000)
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush, 30_000)
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    max_entries = Keyword.get(opts, :max_entries, @transport_batch_size)

    state = %{
      entries: [],
      count: 0,
      max_entries: max_entries,
      flush_interval: Keyword.get(opts, :flush_interval, @default_flush_interval),
      client: Keyword.get(opts, :client, Client),
      client_opts: Keyword.get(opts, :client_opts, []),
      admitted: 0,
      completed: 0,
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
  def handle_call({:log, entry}, _from, %{count: count, max_entries: max} = state)
      when count >= max do
    case flush_entries(state) do
      {:ok, state} -> {:reply, :ok, accept(state, entry)}
      {:error, reason, state} -> {:reply, {:error, {:logs_transport_full, reason}}, state}
    end
  end

  def handle_call({:log, entry}, _from, state), do: {:reply, :ok, accept(state, entry)}

  def handle_call(:flush, _from, state) do
    case flush_entries(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     Map.take(state, [:count, :max_entries, :admitted, :completed, :failed_flushes, :last_error]),
     state}
  end

  @impl true
  def handle_info(:flush, state) do
    state =
      case flush_entries(state) do
        {:ok, state} -> state
        {:error, _reason, state} -> state
      end

    schedule_flush(state.flush_interval)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.install_logger, do: :logger.remove_handler(LoggerHandler.handler_id())
    _ = flush_entries(state)
    :ok
  end

  defp accept(state, entry) do
    %{
      state
      | entries: [entry | state.entries],
        count: state.count + 1,
        admitted: state.admitted + 1
    }
  end

  defp flush_entries(%{count: 0} = state), do: {:ok, state}

  defp flush_entries(state) do
    case state.client.ingest(Enum.reverse(state.entries), state.client_opts) do
      {:ok, count} when count == state.count ->
        {:ok,
         %{
           state
           | entries: [],
             count: 0,
             completed: state.completed + count,
             last_error: nil
         }}

      result ->
        reason = {:incomplete_logs_transport_flush, result}

        :telemetry.execute(
          [:timeless_ui, :logs_data_plane, :flush, :error],
          %{entries: state.count},
          %{reason: reason}
        )

        {:error, reason,
         %{state | failed_flushes: state.failed_flushes + 1, last_error: inspect(reason)}}
    end
  end

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

  defp schedule_flush(interval), do: Process.send_after(self(), :flush, interval)
end
