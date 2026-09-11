defmodule TimelessUIWeb.CollectionSafetyTest do
  use TimelessUIWeb.ConnCase

  import Phoenix.LiveViewTest
  import TimelessUI.AccountsFixtures

  setup %{conn: conn} do
    %{conn: log_in_user(conn, user_fixture(%{role: "admin"}))}
  end

  test "poller collection pages use streams and survive stale or forged ids", %{conn: conn} do
    {:ok, _host} = TimelessUI.Poller.Hosts.create_host(%{name: "edge", ip: "127.0.0.1"})

    {:ok, _request} =
      TimelessUI.Poller.Requests.create_request(%{name: "ping", type: "icmp_ping"})

    {:ok, _schedule} =
      TimelessUI.Poller.Schedules.create_schedule(%{name: "minute", cron: "* * * * *"})

    pages = [
      {"/poller/hosts", "#poller-hosts", "edit_host", "#poller-hosts-page"},
      {"/poller/requests", "#poller-requests", "edit_request", "#poller-requests-page"},
      {"/poller/schedules", "#poller-schedules", "edit_schedule", "#poller-schedules-page"}
    ]

    for {path, stream_id, event, page_id} <- pages do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, stream_id <> ~s([phx-update="stream"]))

      render_click(view, event, %{"id" => "not-an-id"})
      assert has_element?(view, page_id)

      render_click(view, event, %{"id" => "999999999"})
      assert has_element?(view, page_id)
    end
  end

  test "admin users render as a stream and stale ids do not terminate the view", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/users")
    assert has_element?(view, ~s(#admin-users[phx-update="stream"]))
    assert has_element?(view, ~s(#user_username[phx-debounce="300"]))
    assert has_element?(view, ~s(#user_password[phx-debounce="300"]))

    render_click(view, "show_reset", %{"id" => "999999999"})
    assert has_element?(view, "#create_user_form")
  end

  test "scrape target text inputs debounce validation traffic", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/scrape-targets")
    view |> element("#add-scrape-target") |> render_click()

    assert has_element?(view, ~s(#scrape-target-job-name[phx-debounce="300"]))
    assert has_element?(view, ~s(#scrape-target-address[phx-debounce="300"]))
    assert has_element?(view, ~s(#scrape-target-metrics-path[phx-debounce="300"]))
    assert has_element?(view, ~s(#scrape-target-label-key-0[phx-debounce="300"]))
    assert has_element?(view, ~s(#scrape-target-label-value-0[phx-debounce="300"]))
  end
end
