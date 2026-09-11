defmodule TimelessUI.Poller.MetricsWriter do
  @moduledoc """
  Bridge between poller collectors and the configured metrics adapter.

  Production selects the Rust data plane. The embedded adapter remains
  available only for the documented offline rollback mode.
  """

  require Logger

  @doc """
  Write a list of collector metric maps to the TimelessMetrics store.

  Each metric is a map with keys: name, host, type, labels, val, ts.
  These are converted to `{metric_name, labels_map, value, timestamp}` tuples
  for `TimelessMetrics.write_batch/2`.
  """
  def write_metrics(metrics, opts \\ []) do
    writer = Keyword.get(opts, :writer, metrics_writer())

    case writer do
      __MODULE__ -> write_embedded(metrics, opts)
      module when is_atom(module) -> module.write_metrics(metrics, opts)
    end
  rescue
    error ->
      Logger.error("Failed to write metrics through configured adapter: #{inspect(error)}")
      {:error, error}
  end

  @doc false
  def write_embedded(metrics, opts \\ []) do
    store = Keyword.get(opts, :store, metrics_store())

    {text_metrics, numeric_metrics} =
      Enum.split_with(metrics, fn m -> Map.get(m, :val_type) == :text end)

    with :ok <- write_embedded_batch(store, :write_batch, numeric_metrics),
         :ok <- write_embedded_batch(store, :write_text_batch, text_metrics) do
      :ok
    end
  end

  defp write_embedded_batch(_store, _operation, []), do: :ok

  defp write_embedded_batch(store, operation, metrics) do
    entries =
      Enum.map(metrics, fn metric ->
        labels =
          Map.merge(
            %{"host" => metric.host, "type" => metric.type},
            metric.labels || %{}
          )

        {metric.name, labels, metric.val, metric.ts}
      end)

    case apply(TimelessMetrics, operation, [store, entries]) do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_metrics_write_result, other}}
    end
  rescue
    error ->
      Logger.error("Failed to write #{operation} metrics: #{inspect(error)}")
      {:error, error}
  end

  defp metrics_writer do
    config = Application.get_env(:timeless_ui, :poller, [])
    Keyword.get(config, :metrics_writer, __MODULE__)
  end

  defp metrics_store do
    config = Application.get_env(:timeless_ui, :poller, [])
    Keyword.get(config, :metrics_store, :timeless_metrics)
  end
end
