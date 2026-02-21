defmodule TimelessUIWeb.PageController do
  use TimelessUIWeb, :controller

  def home(conn, _params) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      redirect(conn, to: ~p"/canvases")
    else
      redirect(conn, to: ~p"/users/log-in")
    end
  end
end
