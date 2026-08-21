defmodule TimelessUI.MetricsDataPlane.Writer do
  @moduledoc """
  Batches numeric poller results into the Rust data plane's public
  VictoriaMetrics import surface.

  The HTTP batch is transport only. Series buffering, the authoritative
  4,096-point compression threshold, rollups, and durability remain inside
  the timeless-libsql extension.
  """

  alias TimelessUI.MetricsDataPlane.Client

  def write_metrics(metrics, opts \\ []) when is_list(metrics) do
    {text, numeric} = Enum.split_with(metrics, &(Map.get(&1, :val_type) == :text))

    with :ok <- import_numeric(numeric, opts) do
      case text do
        [] ->
          :ok

        text ->
          reason = {:unsupported_capability, :text_metrics, length(text)}

          :telemetry.execute(
            [:timeless_ui, :metrics_data_plane, :unsupported],
            %{text_metrics: length(text), completed_numeric_metrics: length(numeric)},
            %{reason: reason}
          )

          {:error, reason}
      end
    end
  end

  defp import_numeric([], _opts), do: :ok

  defp import_numeric(metrics, opts) do
    client = Keyword.get(opts, :client, Client)
    client_opts = Keyword.get(opts, :client_opts, [])

    with {:ok, body} <- encode(metrics) do
      client.import_victoria(body, client_opts)
    end
  end

  defp encode(metrics) do
    metrics
    |> Enum.reduce_while({:ok, %{}}, fn metric, {:ok, groups} ->
      with {:ok, key, timestamp, value} <- normalize(metric) do
        groups =
          Map.update(groups, key, {[value], [timestamp]}, fn {values, timestamps} ->
            {[value | values], [timestamp | timestamps]}
          end)

        {:cont, {:ok, groups}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, groups} ->
        lines =
          groups
          |> Enum.sort_by(fn {{name, labels}, _points} -> {name, labels} end)
          |> Enum.map(fn {{name, labels}, {values, timestamps}} ->
            Jason.encode!(%{
              "metric" => Map.put(labels, "__name__", name),
              "values" => Enum.reverse(values),
              "timestamps" => Enum.reverse(timestamps)
            })
          end)

        {:ok, Enum.join(lines, "\n") <> "\n"}

      {:error, _reason} = error ->
        error
    end
  end

  # `ts` is epoch seconds, per `TimelessUI.Poller.Collector.metric_data`; the
  # import surface takes milliseconds.
  defp normalize(%{name: name, host: host, type: type, val: value, ts: timestamp} = metric)
       when is_binary(name) and is_number(value) and is_integer(timestamp) do
    if plausible_seconds?(timestamp) do
      labels =
        %{"host" => to_string(host), "type" => to_string(type)}
        |> Map.merge(stringify_labels(Map.get(metric, :labels) || %{}))

      {:ok, {name, labels}, timestamp * 1_000, value * 1.0}
    else
      {:error, {:implausible_timestamp, name, timestamp}}
    end
  end

  defp normalize(metric), do: {:error, {:invalid_numeric_metric, metric}}

  # A collector emitting milliseconds instead of seconds is off by 1000, which
  # ingests cleanly and lands the sample ~56,000 years out: the write succeeds,
  # the series shows up in /api/v1/series, and no query ever returns a point.
  # There is no honest reading of a poller sample a day either side of now, so
  # refuse it here where the error is still attributable to a collector.
  defp plausible_seconds?(timestamp) do
    now = System.system_time(:second)
    timestamp > now - 86_400 * 366 and timestamp < now + 86_400
  end

  defp stringify_labels(labels) when is_map(labels) do
    Map.new(labels, fn {key, value} -> {to_string(key), to_string(value)} end)
  end
end
