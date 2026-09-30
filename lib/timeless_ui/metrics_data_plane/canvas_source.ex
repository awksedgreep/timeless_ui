defmodule TimelessUI.MetricsDataPlane.CanvasSource do
  @moduledoc """
  Opt-in Canvas data source that routes graph history through the Rust process.

  Three callbacks go to the plane: `metric_range/5` (one series, from the
  export route), and `metric_range/6` and `top_series/5` (series combined,
  filtered, and ranked, from the PromQL routes). Every live status,
  subscription, metadata, and product-oriented callback remains with the
  configured Elixir fallback source.

  With `source: :fallback`, all three go to the fallback. Exporting them is
  what offers the `top_n` element and the graph aggregate to the canvas, so
  a fallback that does not have `metric_range/6` and `top_series/5` answers
  those with an error.

  What an element selects by is `TimelessCanvas.Canvas.Element.query_labels/1`
  and `query_matchers/1`: every field that does not configure the element.

  ## Options

    * `:lookback_seconds` — how far back a sample still counts as the
      present, for the PromQL routes, unless the element sets a `window`.
      Default `30`. The plane's own is five minutes, which counts a series
      for five minutes after it has stopped reporting.
  """

  @behaviour TimelessCanvas.DataSource

  alias TimelessCanvas.Canvas.Element
  alias TimelessUI.MetricsDataPlane.Client
  alias TimelessUI.MetricsDataPlane.PromQL

  @default_lookback_seconds 30
  # A graph's window, in points, at which the canvas downsamples anyway.
  @range_steps 300

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
         lookback_seconds: fetch(config, :lookback_seconds, @default_lookback_seconds),
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
    labels = Element.query_labels(element)
    from_seconds = DateTime.to_unix(from, :second)
    to_seconds = DateTime.to_unix(to, :second)

    with {:ok, series} <-
           state.client.export(metric, labels, from_seconds, to_seconds, state.client_opts),
         {:ok, points} <- one_series(series, metric, labels) do
      {:ok, points}
    end
  end

  @impl true
  def metric_range(%{source: :fallback} = state, element, metric, from, to, opts) do
    fallback_or_unsupported(state, :metric_range, [
      state.fallback_state,
      element,
      metric,
      from,
      to,
      opts
    ])
  end

  def metric_range(state, element, metric, %DateTime{} = from, %DateTime{} = to, opts) do
    matchers = Element.query_matchers(element)
    from_seconds = DateTime.to_unix(from, :second)
    to_seconds = DateTime.to_unix(to, :second)
    step = max(div(to_seconds - from_seconds, @range_steps), 1)
    query = PromQL.range_query(metric, matchers, opts)

    with {:ok, body} <-
           state.client.prometheus_range(
             query,
             from_seconds,
             to_seconds,
             step,
             promql_opts(state, opts)
           ),
         {:ok, series} <- PromQL.series(body) do
      case {Keyword.get(opts, :aggregate), series} do
        # Combined, there is one series, or none.
        {aggregate, [%{points: points} | _]} when not is_nil(aggregate) -> {:ok, points}
        {_aggregate, []} -> {:ok, []}
        # Not combined, it is one series as metric_range/5 draws one.
        {nil, [%{points: points}]} -> {:ok, points}
        {nil, _several} -> {:error, {:ambiguous_series, metric, matchers}}
      end
    end
  end

  @impl true
  def top_series(%{source: :fallback} = state, element, metric, time, opts) do
    fallback_or_unsupported(state, :top_series, [
      state.fallback_state,
      element,
      metric,
      time,
      opts
    ])
  end

  def top_series(state, element, metric, %DateTime{} = time, opts) do
    query = PromQL.top_query(metric, Element.query_matchers(element), opts)

    with {:ok, body} <-
           state.client.prometheus_instant(
             query,
             DateTime.to_unix(time, :second),
             promql_opts(state, opts)
           ) do
      PromQL.rows(body, Keyword.get(opts, :order, :desc))
    end
  end

  defp promql_opts(state, opts) do
    lookback = Keyword.get(opts, :window) || state.lookback_seconds
    Keyword.put(state.client_opts, :lookback_delta, lookback)
  end

  defp fallback_or_unsupported(state, function, args) do
    if function_exported?(state.fallback, function, length(args)),
      do: apply(state.fallback, function, args),
      else: {:error, {:unsupported_by_fallback, function}}
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

  # The one series the element asks for. A series has every label it was
  # written with, and an element names the ones that pick it out: a process
  # is asked for by `host` and `proc`, and its series has `pid`, `comm`,
  # `user`, and `unit` besides. So a series matches when it has the
  # element's labels, whatever else it has. Two that match is still an
  # error, and not the first of them: an element that does not say which
  # series it means is not drawn as if it did.
  defp one_series(series, metric, labels) do
    matches =
      Enum.filter(series, fn row ->
        row.metric == metric and is_map(row.labels) and
          Enum.all?(labels, fn {key, value} -> Map.get(row.labels, key) == value end)
      end)

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
