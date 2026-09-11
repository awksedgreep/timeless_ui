defmodule TimelessUI.Poller.Dispatcher do
  @moduledoc """
  Bounded-concurrency job dispatcher for poller collection jobs.
  Jobs wait in a bounded, jittered queue before a supervised task is started,
  so delayed work never consumes a concurrency slot.
  """

  use GenServer

  require Logger

  alias TimelessUI.Poller.MetricsWriter
  alias TimelessUI.MetricsDataPlane.Client, as: MetricsDataPlaneClient

  alias TimelessUI.Poller.Collectors.{
    IcmpCollector,
    PrometheusCollector,
    MikrotikRestCollector,
    SnmpCollector
  }

  defstruct queue: :gb_trees.empty(),
            tasks: MapSet.new(),
            max_concurrency: 50,
            max_queue: 2_000,
            jitter_ms: 30_000,
            sequence: 0,
            dispatch_timer: nil,
            total_dispatched: 0,
            total_dropped: 0

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def enqueue(job) do
    case enqueue_many([job]) do
      %{accepted: 1} -> :ok
      %{accepted: 0} -> {:error, :overload}
    end
  end

  def enqueue_many(jobs) when is_list(jobs),
    do: GenServer.call(__MODULE__, {:enqueue_many, jobs})

  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      max_concurrency: Keyword.get(opts, :max_concurrency, 50),
      max_queue: Keyword.get(opts, :max_queue, 2_000),
      jitter_ms: Keyword.get(opts, :jitter_ms, 30_000)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue_many, jobs}, _from, state) do
    available = max(state.max_queue - :gb_trees.size(state.queue), 0)
    {accepted, dropped} = Enum.split(jobs, available)
    now = System.monotonic_time(:millisecond)

    state =
      Enum.reduce(accepted, state, fn job, state ->
        sequence = state.sequence + 1
        ready_at = now + jitter(state.jitter_ms)
        queue = :gb_trees.insert({ready_at, sequence}, job, state.queue)
        %{state | queue: queue, sequence: sequence}
      end)

    dropped_count = length(dropped)

    if dropped_count > 0 do
      :telemetry.execute(
        [:poller, :dispatcher, :overload],
        %{dropped: dropped_count, queued: :gb_trees.size(state.queue)},
        %{status: :overload}
      )
    end

    state = %{state | total_dropped: state.total_dropped + dropped_count}
    reply = %{accepted: length(accepted), dropped: dropped_count}
    {:reply, reply, dispatch_pending(state)}
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      running: MapSet.size(state.tasks),
      queued: :gb_trees.size(state.queue),
      max_concurrency: state.max_concurrency,
      max_queue: state.max_queue,
      total_dispatched: state.total_dispatched,
      total_dropped: state.total_dropped
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if MapSet.member?(state.tasks, ref) do
      state = %{state | tasks: MapSet.delete(state.tasks, ref)}

      if reason != :normal do
        Logger.warning("Poller job crashed: #{inspect(reason)}")
        :telemetry.execute([:poller, :job, :crash], %{count: 1}, %{status: :crashed})
      end

      {:noreply, dispatch_pending(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(:dispatch, state),
    do: {:noreply, dispatch_pending(%{state | dispatch_timer: nil})}

  defp dispatch_pending(state) do
    state = cancel_dispatch_timer(state)

    cond do
      MapSet.size(state.tasks) >= state.max_concurrency ->
        state

      :gb_trees.is_empty(state.queue) ->
        state

      true ->
        {key = {ready_at, _sequence}, job, queue} = :gb_trees.take_smallest(state.queue)
        now = System.monotonic_time(:millisecond)

        if ready_at <= now do
          task =
            Task.Supervisor.async_nolink(TimelessUI.Poller.TaskSupervisor, fn ->
              execute_job(job)
            end)

          state = %{
            state
            | queue: queue,
              tasks: MapSet.put(state.tasks, task.ref),
              total_dispatched: state.total_dispatched + 1
          }

          dispatch_pending(state)
        else
          queue = :gb_trees.insert(key, job, queue)
          timer = Process.send_after(self(), :dispatch, ready_at - now)
          %{state | queue: queue, dispatch_timer: timer}
        end
    end
  end

  defp cancel_dispatch_timer(%{dispatch_timer: nil} = state), do: state

  defp cancel_dispatch_timer(state) do
    Process.cancel_timer(state.dispatch_timer)
    %{state | dispatch_timer: nil}
  end

  defp jitter(0), do: 0
  defp jitter(maximum), do: :rand.uniform(maximum + 1) - 1

  defp execute_job(%{host: host, request: request}) do
    if request.type == "prometheus" and rust_prometheus_owner?() do
      Logger.debug(
        "Skipping #{request.name} for #{host.name}: Rust target manager owns Prometheus scraping"
      )

      :telemetry.execute([:poller, :job, :skipped], %{count: 1}, %{
        type: request.type,
        status: :rust_owner
      })

      :ok
    else
      execute_job_owned(%{host: host, request: request})
    end
  end

  defp execute_job_owned(%{host: host, request: request}) do
    :telemetry.execute([:poller, :job, :start], %{count: 1}, %{
      type: request.type,
      status: :started
    })

    collector = collector_for_type(request.type)
    run_collector(collector, host, request)
  end

  defp rust_prometheus_owner?,
    do: Application.get_env(:timeless_ui, :metrics_scraper_mode, :embedded) == :rust

  defp run_collector(nil, host, request) do
    Logger.warning(
      "Skipping job #{request.name} for #{host.name}: no collector for type #{request.type}"
    )
  end

  defp run_collector(collector, host, request) do
    config = Application.get_env(:timeless_ui, :poller, [])

    result =
      if request.type == "prometheus" and
           Application.get_env(:timeless_ui, :metrics_scraper_mode, :embedded) == :rust do
        run_rust_prometheus_scrape(host, request, config)
      else
        collector.execute(host, request, request.config || %{}, config)
      end

    case result do
      {:ok, metrics} ->
        case MetricsWriter.write_metrics(metrics) do
          :ok ->
            :telemetry.execute([:poller, :job, :complete], %{metrics_count: length(metrics)}, %{
              type: request.type,
              status: :complete
            })

          {:error, reason} ->
            Logger.warning(
              "Poller result was not fully persisted: #{host.name}/#{request.name}: #{inspect(reason)}"
            )

            :telemetry.execute([:poller, :job, :error], %{count: 1}, %{
              type: request.type,
              status: :write_error
            })
        end

      {:error, reason} ->
        Logger.debug("Poller job failed: #{host.name}/#{request.name}: #{inspect(reason)}")

        :telemetry.execute([:poller, :job, :error], %{count: 1}, %{
          type: request.type,
          status: :collection_error
        })
    end
  end

  defp run_rust_prometheus_scrape(host, request, config) do
    case PrometheusCollector.execute_raw(host, request, request.config || %{}, config) do
      {:ok, body} ->
        case MetricsDataPlaneClient.import_prometheus(body) do
          :ok -> {:ok, []}
          {:error, reason} -> {:error, {:prometheus_import, reason}}
        end

      {:error, reason} ->
        case MetricsWriter.write_metrics([
               PrometheusCollector.failure_metric(host, System.system_time(:millisecond))
             ]) do
          :ok -> {:error, {:prometheus_scrape, reason}}
          {:error, write_reason} -> {:error, {:prometheus_scrape, reason, write_reason}}
        end
    end
  end

  defp collector_for_type("icmp_ping"), do: IcmpCollector
  defp collector_for_type("prometheus"), do: PrometheusCollector
  defp collector_for_type("mikrotik_rest"), do: MikrotikRestCollector
  defp collector_for_type(type) when type in ~w(snmpget snmpwalk snmpbulkwalk), do: SnmpCollector

  defp collector_for_type(other) do
    Logger.warning("No collector for type: #{other}")
    nil
  end
end
