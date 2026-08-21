defmodule TimelessUIWeb.PollerLive.NavTest do
  @moduledoc """
  The poller pages are peers, and each must offer every other one.

  They were previously a hub and its spokes: only the dashboard linked out, so
  moving between Hosts, Requests and Schedules meant returning to the dashboard
  in between. Nothing was broken, so nothing failed -- which is exactly why this
  is worth asserting.
  """
  use TimelessUIWeb.ConnCase

  import Phoenix.LiveViewTest
  import TimelessUI.AccountsFixtures

  @sections ["/poller", "/poller/hosts", "/poller/requests", "/poller/schedules"]

  setup %{conn: conn} do
    %{conn: log_in_user(conn, user_fixture(%{role: "admin"}))}
  end

  for path <- @sections do
    test "#{path} links to every poller section", %{conn: conn} do
      {:ok, _lv, html} = live(conn, unquote(path))

      for section <- @sections do
        assert html =~ ~s(href="#{section}"),
               "#{unquote(path)} is missing a link to #{section}"
      end
    end
  end

  test "the current section is the active tab", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/poller/hosts")

    # Marked on the link itself, so it survives however the strip is styled.
    assert html =~ ~s(aria-current="page")

    active =
      html
      |> Floki.parse_document!()
      |> Floki.find(~s([aria-current="page"]))

    assert [tab] = active
    assert Floki.attribute(tab, "href") == ["/poller/hosts"]
  end
end
