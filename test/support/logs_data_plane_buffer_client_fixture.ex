defmodule TimelessUI.LogsDataPlaneBufferClientFixture do
  @moduledoc false

  def ingest(entries, opts) do
    if notify = Keyword.get(opts, :notify), do: send(notify, {:logs_ingest, entries})
    Keyword.get(opts, :result, {:ok, length(entries)})
  end
end
