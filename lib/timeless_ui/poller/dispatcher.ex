defmodule TimelessUI.Poller.Dispatcher do
  @moduledoc """
  Bounded-concurrency job dispatcher for poller collection jobs.
  Uses a queue and Task.Supervisor.async_nolink for execution.
  Applies random backoff (0-30s) before each job.
  """

  use GenServer

  require Logger

  alias TimelessUI.Poller.{MetricsWriter, Collectors.IcmpCollector}

  defstruct queue: :queue.new(),
            running: 0,
            max_concurrency: 50,
            total_dispatched: 0

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def enqueue(job) do
    GenServer.cast(__MODULE__, {:enqueue, job})
  end

  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @impl true
  def init(opts) do
    max_concurrency = Keyword.get(opts, :max_concurrency, 50)

    state = %__MODULE__{
      max_concurrency: max_concurrency
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:enqueue, job}, state) do
    state = %{state | queue: :queue.in(job, state.queue)}
    {:noreply, dispatch_pending(state)}
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    state = %{state | running: state.running - 1}
    {:noreply, dispatch_pending(state)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    state = %{state | running: state.running - 1}

    if reason != :normal do
      Logger.warning("Poller job crashed: #{inspect(reason)}")
      :telemetry.execute([:poller, :job, :crash], %{count: 1}, %{reason: reason})
    end

    {:noreply, dispatch_pending(state)}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      running: state.running,
      queued: :queue.len(state.queue),
      max_concurrency: state.max_concurrency,
      total_dispatched: state.total_dispatched
    }

    {:reply, stats, state}
  end

  defp dispatch_pending(state) do
    if state.running < state.max_concurrency and not :queue.is_empty(state.queue) do
      {{:value, job}, queue} = :queue.out(state.queue)

      state = %{
        state
        | queue: queue,
          running: state.running + 1,
          total_dispatched: state.total_dispatched + 1
      }

      Task.Supervisor.async_nolink(TimelessUI.Poller.TaskSupervisor, fn ->
        backoff = :rand.uniform(30_000)
        Process.sleep(backoff)
        execute_job(job)
      end)

      dispatch_pending(state)
    else
      state
    end
  end

  defp execute_job(%{host: host, request: request}) do
    :telemetry.execute([:poller, :job, :start], %{count: 1}, %{
      host: host.name,
      request: request.name,
      type: request.type
    })

    collector = collector_for_type(request.type)
    config = Application.get_env(:timeless_ui, :poller, [])

    case apply(collector, :execute, [host, request, request.config, config]) do
      {:ok, metrics} ->
        MetricsWriter.write_metrics(metrics)

        :telemetry.execute([:poller, :job, :complete], %{metrics_count: length(metrics)}, %{
          host: host.name,
          request: request.name,
          type: request.type
        })

      {:error, reason} ->
        Logger.warning("Poller job failed: #{host.name}/#{request.name}: #{inspect(reason)}")

        :telemetry.execute([:poller, :job, :error], %{count: 1}, %{
          host: host.name,
          request: request.name,
          type: request.type,
          reason: reason
        })
    end
  end

  defp collector_for_type("icmp_ping"), do: IcmpCollector

  defp collector_for_type(other) do
    Logger.warning("No collector for type: #{other}")
    IcmpCollector
  end
end
