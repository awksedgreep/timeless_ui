defmodule TimelessUIWeb.PollerNav do
  @moduledoc """
  Section navigation for the poller pages.

  The four poller pages are peers — a host is configured, pointed at a request,
  and put on a schedule, and setting one up means moving between all three. They
  were arranged as a hub and its spokes instead: the dashboard linked out to
  each page, but each page only linked back, so going from Hosts to Requests
  meant returning to the dashboard first.
  """
  use Phoenix.Component
  use TimelessUIWeb, :verified_routes

  attr :current, :atom,
    required: true,
    values: [:dashboard, :hosts, :requests, :schedules],
    doc: "the page being rendered, marked as the active tab"

  def poller_nav(assigns) do
    assigns = assign(assigns, :sections, sections())

    ~H"""
    <div role="tablist" class="tabs tabs-box mb-6">
      <.link
        :for={{id, label, path} <- @sections}
        navigate={path}
        role="tab"
        aria-current={if @current == id, do: "page"}
        class={["tab", @current == id && "tab-active"]}
      >
        {label}
      </.link>
    </div>
    """
  end

  defp sections do
    [
      {:dashboard, "Dashboard", ~p"/poller"},
      {:hosts, "Hosts", ~p"/poller/hosts"},
      {:requests, "Requests", ~p"/poller/requests"},
      {:schedules, "Schedules", ~p"/poller/schedules"}
    ]
  end
end
