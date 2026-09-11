defmodule TimelessUIWeb.PollerLive.Dashboard do
  use TimelessUIWeb, :live_view

  import TimelessUIWeb.PollerNav

  alias TimelessUI.OperationsMonitor

  @impl true
  def mount(_params, _session, socket) do
    stats =
      if connected?(socket),
        do: OperationsMonitor.subscribe(:poller_stats),
        else: OperationsMonitor.snapshot(:poller_stats)

    {:ok,
     assign(socket,
       page_title: "Poller Dashboard",
       scheduler: stats.scheduler,
       dispatcher: stats.dispatcher
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="poller-dashboard-page" class="max-w-4xl mx-auto p-8">
        <.poller_nav current={:dashboard} />

        <div class="flex items-center justify-between mb-8">
          <h1 class="text-2xl font-bold">Poller Dashboard</h1>
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
    </Layouts.app>
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
  def handle_info({:operations_update, :poller_stats, stats}, socket) do
    if socket.assigns.scheduler == stats.scheduler and
         socket.assigns.dispatcher == stats.dispatcher,
       do: {:noreply, socket},
       else: {:noreply, assign(socket, scheduler: stats.scheduler, dispatcher: stats.dispatcher)}
  end
end
