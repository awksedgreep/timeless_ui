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

    {text_metrics, numeric_metrics} =
      Enum.split_with(metrics, fn m -> Map.get(m, :val_type) == :text end)

    if numeric_metrics != [] do
      numeric_entries =
        Enum.map(numeric_metrics, fn metric ->
          labels =
            Map.merge(
              %{"host" => metric.host, "type" => metric.type},
              metric.labels || %{}
            )

          {metric.name, labels, metric.val, metric.ts}
        end)

      try do
        apply(TimelessMetrics, :write_batch, [store, numeric_entries])
      rescue
        e -> Logger.error("Failed to write numeric metrics: #{inspect(e)}")
      end
    end

    if text_metrics != [] do
      text_entries =
        Enum.map(text_metrics, fn metric ->
          labels =
            Map.merge(
              %{"host" => metric.host, "type" => metric.type},
              metric.labels || %{}
            )

          {metric.name, labels, metric.val, metric.ts}
        end)

      try do
        apply(TimelessMetrics, :write_text_batch, [store, text_entries])
      rescue
        e -> Logger.error("Failed to write text metrics: #{inspect(e)}")
      end
    end

    :ok
  end

  defp metrics_store do
    config = Application.get_env(:timeless_ui, :poller, [])
    Keyword.get(config, :metrics_store, :timeless_metrics)
  end
end
