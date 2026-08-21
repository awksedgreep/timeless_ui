defmodule TimelessUIWeb.HealthBadgeTest do
  @moduledoc """
  The badge renders the health string the data plane reported.

  It previously matched on %{health: ...} while being handed the bare string,
  so every clause fell through to the catch-all and every target displayed
  grey "unknown" regardless of what it was doing — including targets that were
  scraping happily.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias TimelessUIWeb.ScrapeTargetLive

  defp badge(health) do
    render_component(&ScrapeTargetLive.health_badge/1, health: health)
  end

  test "an up target reads up and is green" do
    html = badge("up")
    assert html =~ "up"
    assert html =~ "bg-success"
  end

  test "a down target reads down and is red" do
    html = badge("down")
    assert html =~ "down"
    assert html =~ "bg-error"
  end

  test "genuinely unknown health still reads unknown" do
    # nil is what a target reports before its first scrape completes; that is a
    # real state and must keep saying so.
    assert badge(nil) =~ "unknown"
    assert badge("") =~ "unknown"
  end

  test "an unrecognised health is shown rather than hidden" do
    # If the data plane grows a new state, showing it beats silently calling it
    # unknown — which is how this bug stayed invisible.
    html = badge("degraded")
    assert html =~ "degraded"
  end
end
