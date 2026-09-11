defmodule TimelessUI.Poller.Scheduler do
  @moduledoc """
  Ticks every minute (aligned to :00) and evaluates enabled schedules.
  Matches cron expressions against the current time, resolves host x request
  combinations, and enqueues jobs to the Dispatcher.
  """

  use GenServer

  require Logger

  alias TimelessUI.Poller.{Schedules, Schedule, Hosts, Requests, Dispatcher}

  defstruct [
    :timer_ref,
    schedules_total: 0,
    last_tick: nil,
    jobs_enqueued: 0,
    jobs_dropped: 0,
    max_jobs_per_tick: 2_000,
    cron_cache: %{}
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{max_jobs_per_tick: Keyword.get(opts, :max_jobs_per_tick, 2_000)}
    {:ok, schedule_next_tick(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    now = DateTime.utc_now()
    state = %{state | last_tick: now}

    schedules = Schedules.list_enabled_schedules()
    {due_schedules, cron_cache} = due_schedules(schedules, now, state.cron_cache)

    {jobs_enqueued, jobs_dropped} =
      if due_schedules == [] do
        {0, 0}
      else
        hosts = Hosts.list_hosts()
        requests = Requests.list_requests()
        enqueue_due(due_schedules, hosts, requests, state.max_jobs_per_tick)
      end

    state = %{
      state
      | schedules_total: length(schedules),
        jobs_enqueued: state.jobs_enqueued + jobs_enqueued,
        jobs_dropped: state.jobs_dropped + jobs_dropped,
        cron_cache: cron_cache
    }

    if jobs_enqueued > 0 do
      Logger.debug("Scheduler tick: enqueued #{jobs_enqueued} jobs")
    end

    {:noreply, schedule_next_tick(state)}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      schedules_total: state.schedules_total,
      last_tick: state.last_tick,
      jobs_enqueued: state.jobs_enqueued,
      jobs_dropped: state.jobs_dropped
    }

    {:reply, stats, state}
  end

  defp schedule_next_tick(state) do
    now = System.system_time(:millisecond)
    ms_into_minute = rem(now, 60_000)
    delay = 60_000 - ms_into_minute

    ref = Process.send_after(self(), :tick, delay)
    %{state | timer_ref: ref}
  end

  @doc false
  def due_schedules(schedules, %DateTime{} = now, cache) do
    naive = DateTime.to_naive(now)

    Enum.reduce(schedules, {[], %{}}, fn schedule, {due, next_cache} ->
      entry =
        case Map.get(cache, schedule.id) do
          {cron, expression} when cron == schedule.cron -> {cron, expression}
          _ -> {schedule.cron, parse_cron(schedule.cron)}
        end

      next_cache = Map.put(next_cache, schedule.id, entry)

      case entry do
        {_cron, {:ok, expression}} ->
          if Crontab.DateChecker.matches_date?(expression, naive),
            do: {[schedule | due], next_cache},
            else: {due, next_cache}

        {_cron, :error} ->
          {due, next_cache}
      end
    end)
    |> then(fn {due, next_cache} -> {Enum.reverse(due), next_cache} end)
  end

  defp parse_cron(cron) do
    case Crontab.CronExpression.Parser.parse(cron) do
      {:ok, expression} -> {:ok, expression}
      {:error, _reason} -> :error
    end
  end

  defp enqueue_due(schedules, hosts, requests, limit) do
    schedules
    |> Enum.reduce({0, 0, true}, fn schedule, {accepted, dropped, accepting?} ->
      {jobs, total} = resolve_jobs(schedule, hosts, requests)
      remaining = limit - accepted

      if accepting? and remaining > 0 do
        offered = Enum.take(jobs, remaining)
        result = Dispatcher.enqueue_many(offered)

        {
          accepted + result.accepted,
          dropped + total - result.accepted,
          result.dropped == 0 and result.accepted == total and accepted + result.accepted < limit
        }
      else
        {accepted, dropped + total, false}
      end
    end)
    |> then(fn {accepted, dropped, _accepting?} -> {accepted, dropped} end)
  end

  defp resolve_jobs(schedule, hosts, requests) do
    host_tags = Schedule.host_tags_list(schedule)
    request_tags = Schedule.request_tags_list(schedule)

    hosts =
      if host_tags == [] do
        hosts
      else
        Enum.filter(hosts, &TimelessUI.Poller.Host.has_all_tags?(&1, host_tags))
      end

    requests =
      if request_tags == [] do
        requests
      else
        Enum.filter(requests, &TimelessUI.Poller.Request.has_all_tags?(&1, request_tags))
      end

    jobs =
      Stream.flat_map(hosts, fn host ->
        Stream.map(requests, fn request ->
          %{host: host, request: request, schedule_id: schedule.id}
        end)
      end)

    {jobs, length(hosts) * length(requests)}
  end
end
