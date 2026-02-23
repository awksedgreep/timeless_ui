defmodule TimelessUI.MetricsAPI do
  @moduledoc """
  Direct function calls to TimelessMetrics.Scraper for scrape target CRUD.

  Uses apply/3 to avoid compile-time dependency on timeless_metrics,
  which is only available at runtime via timeless_stack.
  """

  @scraper :timeless_metrics_scraper

  def list_targets do
    apply(TimelessMetrics.Scraper, :list_targets, [@scraper])
  end

  def get_target(id) do
    apply(TimelessMetrics.Scraper, :get_target, [@scraper, id])
  end

  def create_target(params) when is_map(params) do
    apply(TimelessMetrics.Scraper, :add_target, [@scraper, params])
  end

  def update_target(id, params) when is_map(params) do
    apply(TimelessMetrics.Scraper, :update_target, [@scraper, id, params])
  end

  def delete_target(id) do
    apply(TimelessMetrics.Scraper, :delete_target, [@scraper, id])
  end
end
