defmodule TimelessUIWeb.PollerLive.Dashboard do
  use TimelessUIWeb, :live_view

  alias TimelessUI.Poller.{Scheduler, Dispatcher}

  @refresh_interval :timer.seconds(5)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_interval)

    {:ok,
     socket
     |> assign(page_title: "Poller Dashboard")
     |> load_stats()}
  end

  defp load_stats(socket) do
    scheduler_stats =
      safe_call(fn -> Scheduler.stats() end, %{
        schedules_total: 0,
        last_tick: nil,
        jobs_enqueued: 0
      })

    dispatcher_stats =
      safe_call(fn -> Dispatcher.stats() end, %{
        running: 0,
        queued: 0,
        max_concurrency: 0,
        total_dispatched: 0
      })

    assign(socket,
      scheduler: scheduler_stats,
      dispatcher: dispatcher_stats
    )
  end

  defp safe_call(fun, default) do
    try do
      fun.()
    catch
      :exit, _ -> default
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-8">
      <div class="flex items-center justify-between mb-8">
        <h1 class="text-2xl font-bold">Poller Dashboard</h1>
        <div class="flex gap-2">
          <.link navigate={~p"/poller/hosts"} class="btn btn-sm btn-outline">Hosts</.link>
          <.link navigate={~p"/poller/requests"} class="btn btn-sm btn-outline">Requests</.link>
          <.link navigate={~p"/poller/schedules"} class="btn btn-sm btn-outline">Schedules</.link>
        </div>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title">Scheduler</h2>
            <div class="grid grid-cols-2 gap-4 mt-4">
              <.stat_item label="Schedules" value={@scheduler.schedules_total} />
              <.stat_item label="Jobs Enqueued" value={@scheduler.jobs_enqueued} />
              <.stat_item
                label="Last Tick"
                value={format_tick(@scheduler.last_tick)}
                class="col-span-2"
              />
            </div>
          </div>
        </div>

        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title">Dispatcher</h2>
            <div class="grid grid-cols-2 gap-4 mt-4">
              <.stat_item label="Running" value={@dispatcher.running} />
              <.stat_item label="Queued" value={@dispatcher.queued} />
              <.stat_item label="Max Concurrency" value={@dispatcher.max_concurrency} />
              <.stat_item label="Total Dispatched" value={@dispatcher.total_dispatched} />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp stat_item(assigns) do
    assigns = assign_new(assigns, :class, fn -> "" end)

    ~H"""
    <div class={@class}>
      <span class="text-base-content/60 text-sm">{@label}</span>
      <p class="text-xl font-bold">{@value}</p>
    </div>
    """
  end

  defp format_tick(nil), do: "—"

  defp format_tick(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, load_stats(socket)}
  end
end
