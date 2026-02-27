defmodule TimelessUI.Poller.Supervisor do
  use Supervisor

  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    enabled = Keyword.get(opts, :enabled, false)

    if enabled do
      Logger.info("Poller supervisor starting (enabled: true)")

      TimelessUI.Poller.SnmpKitStarter.ensure_started()

      children = [
        {Task.Supervisor, name: TimelessUI.Poller.TaskSupervisor},
        {TimelessUI.Poller.Dispatcher, opts},
        {TimelessUI.Poller.Scheduler, opts}
      ]

      Supervisor.init(children, strategy: :one_for_one)
    else
      Logger.info("Poller supervisor skipped (enabled: false)")
      :ignore
    end
  end
end
