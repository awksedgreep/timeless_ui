defmodule TimelessUI.TelemetryDataPlane do
  @moduledoc "Phoenix control-plane view of the three Rust process owners."

  alias TimelessUI.Accounts.Scope
  alias TimelessUI.Accounts.User
  alias TimelessUI.TelemetryDataPlane.{Policy, Process}

  @owners %{
    metrics: TimelessUI.MetricsDataPlane.Process,
    logs: TimelessUI.LogsDataPlane.Process,
    traces: TimelessUI.TracesDataPlane.Process
  }

  def status(%Scope{} = current_scope) do
    with :ok <- authorize_admin(current_scope) do
      {:ok, Map.new(@owners, fn {signal, owner} -> {signal, owner_status(owner)} end)}
    end
  end

  def status(%Scope{} = current_scope, signal) do
    with :ok <- authorize_admin(current_scope),
         {:ok, signal} <- normalize_signal(signal),
         {:ok, owner} <- Map.fetch(@owners, signal) do
      {:ok, owner_status(owner)}
    else
      :error -> {:error, :unsupported_signal}
      {:error, _reason} = error -> error
    end
  end

  def retry(%Scope{} = current_scope, signal) do
    with :ok <- authorize_admin(current_scope),
         {:ok, signal} <- normalize_signal(signal),
         {:ok, owner} <- Map.fetch(@owners, signal),
         pid when is_pid(pid) <- GenServer.whereis(owner) do
      Process.retry(owner)
    else
      :error -> {:error, :unsupported_signal}
      nil -> {:error, :data_plane_not_running}
      {:error, _reason} = error -> error
    end
  end

  def refresh_authorization do
    case GenServer.whereis(Policy) do
      pid when is_pid(pid) -> Policy.refresh_all()
      nil -> :ok
    end
  catch
    :exit, reason -> {:error, {:authorization_owner_unavailable, reason}}
  end

  defp owner_status(owner) do
    case GenServer.whereis(owner) do
      pid when is_pid(pid) -> Process.status(owner)
      nil -> %{process_phase: :stopped, process_ready: false, error: :not_running}
    end
  catch
    :exit, reason ->
      %{process_phase: :unavailable, process_ready: false, error: {:owner_exit, reason}}
  end

  defp authorize_admin(%Scope{user: %User{} = user}) do
    if User.admin?(user), do: :ok, else: {:error, :forbidden}
  end

  defp authorize_admin(_scope), do: {:error, :forbidden}

  defp normalize_signal(signal) when signal in [:metrics, :logs, :traces], do: {:ok, signal}
  defp normalize_signal("metrics"), do: {:ok, :metrics}
  defp normalize_signal("logs"), do: {:ok, :logs}
  defp normalize_signal("traces"), do: {:ok, :traces}
  defp normalize_signal(_signal), do: {:error, :unsupported_signal}
end
