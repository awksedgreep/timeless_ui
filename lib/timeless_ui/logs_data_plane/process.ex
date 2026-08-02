defmodule TimelessUI.LogsDataPlane.Process do
  @moduledoc "Signal facade for the neutral telemetry data-plane owner."

  alias TimelessUI.TelemetryDataPlane.Process, as: Owner

  def child_spec(opts) do
    opts = options(opts)
    opts |> Owner.child_spec() |> Map.put(:id, {__MODULE__, Keyword.get(opts, :name, __MODULE__)})
  end

  def start_link(opts), do: opts |> options() |> Owner.start_link()
  def await_ready(server \\ __MODULE__, timeout \\ 10_000), do: Owner.await_ready(server, timeout)
  def endpoint(server \\ __MODULE__), do: Owner.endpoint(server)
  def os_pid(server \\ __MODULE__), do: Owner.os_pid(server)
  def ready?(server \\ __MODULE__), do: Owner.ready?(server)
  def status(server \\ __MODULE__), do: Owner.status(server)
  def retry(server \\ __MODULE__), do: Owner.retry(server)
  def authorization_header(server \\ __MODULE__), do: Owner.authorization_header(server)

  defp options(opts), do: opts |> normalize() |> Keyword.put(:signal, :logs)
  defp normalize(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize(opts) when is_list(opts), do: opts
end
