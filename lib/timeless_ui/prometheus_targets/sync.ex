defmodule TimelessUI.PrometheusTargets.Sync do
  @moduledoc """
  Publishes Phoenix's Prometheus target configuration to the Rust owner once it
  is available after startup. Phoenix remains the control plane; this process
  never scrapes or stores samples.
  """

  use GenServer
  require Logger

  @retry_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    send(self(), :sync)
    {:ok, %{retry?: false}}
  end

  @impl true
  def handle_info(:sync, state) do
    case TimelessUI.MetricsAPI.sync_rust_targets() do
      :ok ->
        {:noreply, %{state | retry?: false}}

      {:error, reason} ->
        Logger.warning("Rust Prometheus target sync unavailable: #{inspect(reason)}")
        schedule_retry(state)
    end
  end

  defp schedule_retry(%{retry?: true} = state), do: {:noreply, state}

  defp schedule_retry(state) do
    Process.send_after(self(), :sync, @retry_ms)

    %{state | retry?: true}
    |> then(&{:noreply, &1})
  end
end
