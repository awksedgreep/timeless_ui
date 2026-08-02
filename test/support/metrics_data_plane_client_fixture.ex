defmodule TimelessUI.MetricsDataPlaneClientFixture do
  def export(metric, labels, from, to, opts) do
    if notify = Keyword.get(opts, :notify) do
      send(notify, {:metrics_export, metric, labels, from, to})
    end

    Keyword.fetch!(opts, :result)
  end
end
