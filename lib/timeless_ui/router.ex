defmodule TimelessUI.Router do
  @moduledoc """
  Provides a `timeless_canvas/2` macro for mounting TimelessUI in a host application's router.

  ## Usage

      import TimelessUI.Router

      scope "/" do
        pipe_through :browser
        timeless_canvas "/canvas"
      end
  """

  defmacro timeless_canvas(path, opts \\ []) do
    session_name = Keyword.get(opts, :as, :timeless_canvas)

    quote do
      scope unquote(path), alias: false, as: false do
        import Phoenix.LiveView.Router, only: [live: 4, live_session: 3]

        live_session unquote(session_name),
          root_layout: {TimelessUIWeb.Layouts, :root} do
          live "/", TimelessUIWeb.CanvasLive, :index, as: unquote(session_name)
        end
      end

      scope unquote(path), alias: false, as: false do
        get "/timeless_ui/assets/*asset", TimelessUI.Assets, :index
      end
    end
  end
end
