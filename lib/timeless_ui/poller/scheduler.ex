defmodule TimelessUI.Poller.Scheduler do
  @moduledoc """
  Ticks every minute (aligned to :00) and evaluates enabled schedules.
  Matches cron expressions against the current time, resolves host x request
  combinations, and enqueues jobs to the Dispatcher.
  """

  use GenServer

  require Logger

  alias TimelessUI.Poller.{Schedules, Hosts, Requests, Dispatcher}

  defstruct [:timer_ref, schedules_total: 0, last_tick: nil, jobs_enqueued: 0]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @impl true
  def init(_opts) do
    state = %__MODULE__{}
    {:ok, schedule_next_tick(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    now = DateTime.utc_now()
    state = %{state | last_tick: now}

    schedules = Schedules.list_enabled_schedules()
    state = %{state | schedules_total: length(schedules)}

    jobs_enqueued =
      schedules
      |> Enum.filter(&cron_matches?(&1.cron, now))
      |> Enum.reduce(0, fn schedule, acc ->
        jobs = resolve_jobs(schedule)
        Enum.each(jobs, &Dispatcher.enqueue/1)
        acc + length(jobs)
      end)

    state = %{state | jobs_enqueued: state.jobs_enqueued + jobs_enqueued}

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
      jobs_enqueued: state.jobs_enqueued
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

  defp cron_matches?(cron_str, %DateTime{} = now) do
    case Crontab.CronExpression.Parser.parse(cron_str) do
      {:ok, expr} ->
        naive = DateTime.to_naive(now)
        Crontab.DateChecker.matches_date?(expr, naive)

      {:error, _} ->
        false
    end
  end

  defp resolve_jobs(schedule) do
    host_groups = schedule.host_groups || %{}
    request_groups = schedule.request_groups || %{}

    hosts =
      if host_groups == %{} do
        Hosts.list_hosts()
      else
        Hosts.list_hosts_by_group(host_groups)
      end

    requests =
      if request_groups == %{} do
        Requests.list_requests()
      else
        Requests.list_requests_by_group(request_groups)
      end

    for host <- hosts, request <- requests do
      %{host: host, request: request, schedule_id: schedule.id}
    end
  end
end
