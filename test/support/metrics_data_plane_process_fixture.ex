defmodule TimelessUI.MetricsDataPlaneProcessFixture do
  @moduledoc false

  use GenServer

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @impl true
  def init(opts), do: {:ok, Map.new(opts)}

  @impl true
  def handle_call(:await_ready, _from, state), do: {:reply, {:ok, state.endpoint}, state}

  def handle_call(:authorization_header, _from, state),
    do: {:reply, {:ok, {"authorization", "Bearer " <> state.token}}, state}
end
