defmodule TimelessUI.Poller.MetricsWriter do
  @moduledoc """
  Bridge between poller collectors and TimelessMetrics storage.

  Converts collector metric maps to TimelessMetrics.write_batch/2 format.
  Uses apply/3 to avoid compile-time dependency on TimelessMetrics.
  """

  require Logger

  @doc """
  Write a list of collector metric maps to the TimelessMetrics store.

  Each metric is a map with keys: name, host, type, labels, val, ts.
  These are converted to `{metric_name, labels_map, value, timestamp}` tuples
  for `TimelessMetrics.write_batch/2`.
  """
  def write_metrics(metrics, opts \\ []) do
    store = Keyword.get(opts, :store, metrics_store())

    entries =
      Enum.map(metrics, fn metric ->
        labels =
          Map.merge(
            %{"host" => metric.host, "type" => metric.type},
            metric.labels || %{}
          )

        {metric.name, labels, metric.val, metric.ts}
      end)

    try do
      apply(TimelessMetrics, :write_batch, [store, entries])
    rescue
      e ->
        Logger.error("Failed to write poller metrics: #{inspect(e)}")
        {:error, e}
    end
  end

  defp metrics_store do
    config = Application.get_env(:timeless_ui, :poller, [])
    Keyword.get(config, :metrics_store, :timeless_metrics)
  end
end
