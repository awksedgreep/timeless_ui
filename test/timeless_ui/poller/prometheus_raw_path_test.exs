defmodule TimelessUI.Poller.PrometheusRawPathTest do
  use ExUnit.Case, async: false

  alias TimelessUI.Poller.Collectors.PrometheusCollector

  test "exposes a raw scrape entry point for the Rust parser" do
    Code.ensure_loaded!(PrometheusCollector)
    assert function_exported?(PrometheusCollector, :execute_raw, 3)
    assert function_exported?(PrometheusCollector, :execute_raw, 4)
    assert function_exported?(PrometheusCollector, :failure_metric, 2)
  end

  test "the Rust client exposes the raw Prometheus import contract" do
    Code.ensure_loaded!(TimelessUI.MetricsDataPlane.Client)
    assert function_exported?(TimelessUI.MetricsDataPlane.Client, :import_prometheus, 1)
    assert function_exported?(TimelessUI.MetricsDataPlane.Client, :import_prometheus, 2)
  end
end
