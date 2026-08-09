defmodule TimelessUI.MetricsDataPlane.CanvasSource do
  @moduledoc """
  Opt-in Canvas data source that routes graph history through the Rust process.

  Session 5 switches only `metric_range/5`. Every live status, subscription,
  metadata, and product-oriented callback remains with the configured Elixir
  fallback source.
  """

  @behaviour TimelessCanvas.DataSource

  alias TimelessUI.MetricsDataPlane.Client

  @internal_graph_fields ~w(
    metric_name
    series_label_key
    series_label_value
    y_min
    y_max
    icon
    os_icon
  )

  @impl true
  def init(config) do
    fallback = fetch(config, :fallback, TimelessCanvas.DataSource.Stub)
    fallback_config = fetch(config, :fallback_config, %{})

    with {:ok, fallback_state} <- fallback.init(fallback_config) do
      {:ok,
       %{
         source: fetch(config, :source, :data_plane),
         client: fetch(config, :client, Client),
         client_opts: fetch(config, :client_opts, []),
         fallback: fallback,
         fallback_state: fallback_state
       }}
    end
  end

  @impl true
  def metric_range(%{source: :fallback} = state, element, metric, from, to) do
    state.fallback.metric_range(state.fallback_state, element, metric, from, to)
  end

  def metric_range(state, element, metric, %DateTime{} = from, %DateTime{} = to) do
    labels = graph_labels(element.meta)
    from_seconds = DateTime.to_unix(from, :second)
    to_seconds = DateTime.to_unix(to, :second)

    with {:ok, series} <-
           state.client.export(metric, labels, from_seconds, to_seconds, state.client_opts),
         {:ok, points} <- exact_points(series, metric, labels) do
      {:ok, points}
    end
  end

  @impl true
  def status(state, element), do: state.fallback.status(state.fallback_state, element)

  @impl true
  def metric(state, element, metric),
    do: state.fallback.metric(state.fallback_state, element, metric)

  @impl true
  def subscribe(state, element) do
    with {:ok, fallback_state} <- state.fallback.subscribe(state.fallback_state, element) do
      {:ok, %{state | fallback_state: fallback_state}}
    end
  end

  @impl true
  def unsubscribe(state, element) do
    with {:ok, fallback_state} <- state.fallback.unsubscribe(state.fallback_state, element) do
      {:ok, %{state | fallback_state: fallback_state}}
    end
  end

  @impl true
  def handle_message(state, message),
    do: state.fallback.handle_message(state.fallback_state, message)

  @impl true
  def metric_at(state, element, metric, time),
    do: state.fallback.metric_at(state.fallback_state, element, metric, time)

  @impl true
  def status_at(state, element, time),
    do: state.fallback.status_at(state.fallback_state, element, time)

  @impl true
  def time_range(state), do: state.fallback.time_range(state.fallback_state)

  @impl true
  def event_density(state, from, to, buckets) do
    optional(state, :event_density, [state.fallback_state, from, to, buckets], [])
  end

  @impl true
  def list_series_for_host(state, host, opts \\ []) do
    optional_with_legacy_opts(
      state,
      :list_series_for_host,
      [state.fallback_state, host, opts],
      [state.fallback_state, host],
      []
    )
  end

  @impl true
  def list_hosts(state, opts \\ []) do
    optional_with_legacy_opts(
      state,
      :list_hosts,
      [state.fallback_state, opts],
      [state.fallback_state],
      []
    )
  end

  @impl true
  def metric_metadata(state, metric_name) do
    optional(state, :metric_metadata, [state.fallback_state, metric_name], {:ok, nil})
  end

  @impl true
  def text_metric(state, element, metric) do
    optional(state, :text_metric, [state.fallback_state, element, metric], :no_data)
  end

  @impl true
  def text_metric_at(state, element, metric, time) do
    optional(state, :text_metric_at, [state.fallback_state, element, metric, time], :no_data)
  end

  @impl true
  def list_label_values(state, label_key, opts \\ []) do
    optional_with_legacy_opts(
      state,
      :list_label_values,
      [state.fallback_state, label_key, opts],
      [state.fallback_state, label_key],
      []
    )
  end

  defp graph_labels(meta) when is_map(meta) do
    labels =
      meta
      |> Map.drop(@internal_graph_fields)
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    case {meta["series_label_key"], meta["series_label_value"]} do
      {key, value} when is_binary(key) and key != "" and is_binary(value) and value != "" ->
        Map.put(labels, key, value)

      _ ->
        labels
    end
  end

  defp graph_labels(_meta), do: %{}

  defp exact_points(series, metric, labels) do
    matches =
      Enum.filter(series, fn row -> row.metric == metric and row.labels == labels end)

    case matches do
      [] -> {:ok, []}
      [%{points: points}] -> {:ok, points}
      _ -> {:error, {:ambiguous_series, metric, labels}}
    end
  end

  defp optional(state, function, args, default) do
    if function_exported?(state.fallback, function, length(args)) do
      apply(state.fallback, function, args)
    else
      default
    end
  end

  defp optional_with_legacy_opts(state, function, args, legacy_args, default) do
    cond do
      function_exported?(state.fallback, function, length(args)) ->
        apply(state.fallback, function, args)

      function_exported?(state.fallback, function, length(legacy_args)) ->
        apply(state.fallback, function, legacy_args)

      true ->
        default
    end
  end

  defp fetch(config, key, default) when is_map(config), do: Map.get(config, key, default)
  defp fetch(config, key, default) when is_list(config), do: Keyword.get(config, key, default)
end
