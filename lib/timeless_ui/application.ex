defmodule TimelessUI.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children =
      metrics_data_plane_children() ++
        [
          TimelessUIWeb.Telemetry,
          TimelessUI.Repo,
          {Ecto.Migrator,
           repos: Application.fetch_env!(:timeless_ui, :ecto_repos), skip: skip_migrations?()},
          {DNSCluster, query: Application.get_env(:timeless_ui, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: TimelessUI.PubSub},
          TimelessCanvas.Supervisor,
          {TimelessUI.Poller.Supervisor,
           Application.get_env(:timeless_ui, :poller, enabled: false)},
          TimelessUIWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: TimelessUI.Supervisor]
    result = Supervisor.start_link(children, opts)

    case TimelessUI.Accounts.ensure_admin_user() do
      :created -> Logger.info("Default admin user created")
      :exists -> :ok
    end

    result
  end

  defp metrics_data_plane_children do
    config = Application.get_env(:timeless_ui, :metrics_data_plane, enabled: false)

    if Keyword.get(config, :enabled, false) do
      [{TimelessUI.MetricsDataPlane.Process, Keyword.delete(config, :enabled)}]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TimelessUIWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
