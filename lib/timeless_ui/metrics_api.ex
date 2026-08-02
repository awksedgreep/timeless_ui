defmodule TimelessUI.MetricsAPI do
  @moduledoc """
  Scrape target control for the embedded rollback data plane.

  The first Rust release deliberately does not claim an embedded scraper CRUD
  surface. Rust mode therefore fails explicitly instead of crossing back to a
  second storage owner.
  """

  @scraper :timeless_metrics_scraper
  @unsupported {:error, {:unsupported_capability, :embedded_prometheus_scraper}}

  def list_targets do
    embedded(fn -> apply(TimelessMetrics.Scraper, :list_targets, [@scraper]) end)
  end

  def get_target(id) do
    embedded(fn -> apply(TimelessMetrics.Scraper, :get_target, [@scraper, id]) end)
  end

  def create_target(params) when is_map(params) do
    embedded(fn -> apply(TimelessMetrics.Scraper, :add_target, [@scraper, params]) end)
  end

  def update_target(id, params) when is_map(params) do
    embedded(fn -> apply(TimelessMetrics.Scraper, :update_target, [@scraper, id, params]) end)
  end

  def delete_target(id) do
    embedded(fn -> apply(TimelessMetrics.Scraper, :delete_target, [@scraper, id]) end)
  end

  defp embedded(operation) do
    if Application.get_env(:timeless_ui, :metrics_scraper_mode, :embedded) == :embedded,
      do: operation.(),
      else: @unsupported
  end
end
