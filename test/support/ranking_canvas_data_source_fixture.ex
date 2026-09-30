defmodule TimelessUI.RankingCanvasDataSourceFixture do
  @moduledoc "A fallback that has the cross-series callbacks."

  def init(config), do: {:ok, config}
  def metric_range(_state, _element, _metric, _from, _to), do: {:ok, []}
  def metric_range(_state, _element, _metric, _from, _to, _opts), do: {:ok, [{1, 1.0}]}

  def top_series(_state, _element, _metric, _time, _opts),
    do: {:ok, [%{labels: %{"from" => "fallback"}, value: 1.0}]}

  def status(_state, _element), do: :ok
  def metric(_state, _element, _metric), do: :no_data
  def subscribe(state, _element), do: {:ok, state}
  def unsubscribe(state, _element), do: {:ok, state}
  def handle_message(_state, _message), do: :ignore
  def metric_at(_state, _element, _metric, _time), do: :no_data
  def status_at(_state, _element, _time), do: :ok
  def time_range(_state), do: :empty
end
