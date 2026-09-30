defmodule TimelessUI.MetricsDataPlaneClientFixture do
  @moduledoc """
  What `CanvasSource` sends to the plane, and a canned answer.

  `opts[:result]` answers `export/5`; `opts[:promql_result]` answers the
  PromQL routes. With `opts[:notify]`, each call is sent there as it was
  made.
  """

  def export(metric, labels, from, to, opts) do
    if notify = Keyword.get(opts, :notify) do
      send(notify, {:metrics_export, metric, labels, from, to})
    end

    Keyword.fetch!(opts, :result)
  end

  def prometheus_instant(query, time, opts) do
    if notify = Keyword.get(opts, :notify) do
      send(notify, {:promql_instant, query, time, Keyword.get(opts, :lookback_delta)})
    end

    Keyword.fetch!(opts, :promql_result)
  end

  def prometheus_range(query, from, to, step, opts) do
    if notify = Keyword.get(opts, :notify) do
      send(notify, {:promql_range, query, from, to, step, Keyword.get(opts, :lookback_delta)})
    end

    Keyword.fetch!(opts, :promql_result)
  end
end
