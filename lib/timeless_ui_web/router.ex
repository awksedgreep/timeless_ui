defmodule TimelessUIWeb.Router do
  use TimelessUIWeb, :router

  import TimelessUIWeb.UserAuth
  import TimelessCanvas.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TimelessUIWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Other scopes may use custom stacks.
  # scope "/api", TimelessUIWeb do
  #   pipe_through :api
  # end

  # LiveDashboard moved to the authenticated admin scope below
  # (/admin/observability) — it now carries the timeless logs and traces
  # pages in every environment, so the unauthenticated dev-only mount is
  # gone rather than duplicated.
  if Application.compile_env(:timeless_ui, :dev_routes) do
    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # Root redirect: authenticated -> /canvas, unauthenticated -> /users/log-in
  scope "/", TimelessUIWeb do
    pipe_through [:browser]

    get "/", PageController, :home
  end

  ## Authentication routes

  scope "/" do
    pipe_through [:browser, :require_authenticated_user]

    live_canvas("/canvas",
      on_mount: [{TimelessUIWeb.UserAuth, :require_authenticated}]
    )
  end

  scope "/", TimelessUIWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{TimelessUIWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  # Operational observability: LiveDashboard carrying the timeless logs and
  # traces pages, reading through the data-plane clients. Admin-only — it
  # exposes raw log content and store internals.
  scope "/admin" do
    pipe_through [:browser, :require_authenticated_user, :require_admin_user]

    import Phoenix.LiveDashboard.Router

    live_dashboard "/observability",
      metrics: TimelessUIWeb.Telemetry,
      additional_pages: [
        logs: TimelessLogsDashboard.Page,
        traces: TimelessTracesDashboard.Page
      ]
  end

  scope "/", TimelessUIWeb do
    pipe_through [:browser, :require_authenticated_user, :require_admin_user]

    get "/admin/api/telemetry/data-planes", TelemetryAdminController, :status
    post "/admin/api/telemetry/data-planes/:signal/retry", TelemetryAdminController, :retry
    post "/admin/api/telemetry/auth/keys/rotate", TelemetryAdminController, :rotate_key
    post "/admin/api/telemetry/auth/keys/:kid/revoke", TelemetryAdminController, :revoke_key

    put "/admin/api/telemetry/auth/policies/:signal/:tenant/:subject",
        TelemetryAdminController,
        :put_policy

    post "/admin/api/telemetry/auth/policies/:signal/:tenant/:subject/bump",
         TelemetryAdminController,
         :bump_auth_version

    post "/admin/api/telemetry/auth/tokens/:signal/:subject",
         TelemetryAdminController,
         :issue_token

    post "/admin/api/telemetry/auth/tokens/revoke", TelemetryAdminController, :revoke_token

    live_session :require_admin_user,
      on_mount: [{TimelessUIWeb.UserAuth, :require_admin}] do
      live "/scrape-targets", ScrapeTargetLive, :index
      live "/poller", PollerLive.Dashboard, :index
      live "/poller/hosts", PollerLive.Hosts, :index
      live "/poller/requests", PollerLive.Requests, :index
      live "/poller/schedules", PollerLive.Schedules, :index
      live "/admin/users", UserLive.Admin, :index
    end
  end

  scope "/", TimelessUIWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{TimelessUIWeb.UserAuth, :mount_current_scope}] do
      live "/users/log-in", UserLive.Login, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
