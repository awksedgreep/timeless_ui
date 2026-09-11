defmodule TimelessUI.BlockingLogsDataPlaneClientFixture do
  @moduledoc false

  def ingest(entries, opts) do
    owner = Keyword.fetch!(opts, :notify)
    send(owner, {:blocking_logs_ingest, self(), entries})

    if Enum.any?(entries, &(&1.message == "event-1")) do
      receive do
        :release_logs_ingest -> {:ok, length(entries)}
      end
    else
      {:ok, length(entries)}
    end
  end
end
