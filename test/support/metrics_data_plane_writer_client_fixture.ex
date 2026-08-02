defmodule TimelessUI.MetricsDataPlaneWriterClientFixture do
  @moduledoc false

  def import_victoria(body, opts) do
    if notify = Keyword.get(opts, :notify), do: send(notify, {:victoria_import, body})
    :ok
  end
end
