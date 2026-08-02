defmodule TimelessUI.CanvasDataSourceFixture do
  def init(config), do: {:ok, config}

  def metric_range(state, _element, _metric, _from, _to), do: state.metric_range

  def status(_state, _element), do: :ok
  def metric(_state, _element, _metric), do: {:ok, 7.0}
  def subscribe(state, _element), do: {:ok, state}
  def unsubscribe(state, _element), do: {:ok, state}
  def handle_message(_state, _message), do: :ignore
  def metric_at(_state, _element, _metric, _time), do: {:ok, 7.0}
  def status_at(_state, _element, _time), do: :ok
  def time_range(_state), do: :empty
end
