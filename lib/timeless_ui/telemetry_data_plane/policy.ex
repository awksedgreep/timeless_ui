defmodule TimelessUI.TelemetryDataPlane.Policy do
  @moduledoc """
  Publishes public verifier policy and supplies short-lived internal tokens.

  Signing keys and policy remain Phoenix-owned. Rust children receive only a
  mode-0600 public policy file; bearer tokens are handed to loopback clients
  on demand and are never included in status output.
  """

  use GenServer

  alias TimelessUI.TelemetryAuth

  @name __MODULE__
  @refresh_margin_seconds 60

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))

  def authorization_header(signal, server \\ @name) do
    GenServer.call(server, {:authorization_header, signal})
  end

  def refresh(signal, server \\ @name), do: GenServer.call(server, {:refresh, signal})
  def refresh_all(server \\ @name), do: GenServer.call(server, :refresh_all)
  def status(server \\ @name), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    with {:ok, planes} <- validate_planes(opts),
         :ok <- publish_all(planes) do
      {:ok, %{planes: planes, tokens: %{}, ready?: true, error: nil}}
    else
      {:error, reason} -> {:stop, {:telemetry_authorization_startup_failed, reason}}
    end
  end

  @impl true
  def handle_call({:authorization_header, signal}, _from, state) do
    with {:ok, signal} <- normalize_signal(signal),
         true <- state.ready? || {:error, :telemetry_authorization_not_ready},
         {:ok, plane} <- fetch_plane(state.planes, signal),
         {:ok, token, expires_at, state} <- current_token(state, plane) do
      {:reply, {:ok, {"authorization", "Bearer " <> token}},
       put_in(state.tokens[signal], %{token: token, expires_at: expires_at})}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:refresh, signal}, _from, state) do
    with {:ok, signal} <- normalize_signal(signal),
         {:ok, plane} <- fetch_plane(state.planes, signal),
         {:ok, _runtime} <-
           TelemetryAuth.ensure_runtime_policy(signal, plane.policy_path, tenant: plane.tenant) do
      {:reply, :ok, %{state | tokens: Map.delete(state.tokens, signal)}}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call(:refresh_all, _from, state) do
    case publish_all(state.planes) do
      :ok -> {:reply, :ok, %{state | tokens: %{}}}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call(:status, _from, state) do
    report =
      Map.new(state.planes, fn {signal, plane} ->
        {signal,
         %{
           ready: state.ready?,
           tenant: plane.tenant,
           policy_path: plane.policy_path,
           token_cached: Map.has_key?(state.tokens, signal)
         }}
      end)

    {:reply, report, state}
  end

  defp current_token(state, plane) do
    now = System.system_time(:second)

    case Map.get(state.tokens, plane.signal) do
      %{token: token, expires_at: expires_at}
      when expires_at > now + @refresh_margin_seconds ->
        {:ok, token, expires_at, state}

      _ ->
        case TelemetryAuth.issue_runtime_token(plane.signal, tenant: plane.tenant) do
          {:ok, %{token: token, claims: %{"exp" => expires_at}}} ->
            {:ok, token, expires_at, state}

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp publish_all(planes) do
    Enum.reduce_while(planes, :ok, fn {signal, plane}, :ok ->
      case TelemetryAuth.ensure_runtime_policy(signal, plane.policy_path, tenant: plane.tenant) do
        {:ok, _runtime} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {signal, reason}}}
      end
    end)
  end

  defp validate_planes(opts) do
    opts
    |> Keyword.fetch!(:planes)
    |> Enum.reduce_while({:ok, %{}, MapSet.new()}, fn configured, {:ok, planes, paths} ->
      configured = normalize_options(configured)

      with :required <- Keyword.get(configured, :auth_mode, :disabled),
           {:ok, signal} <- normalize_signal(Keyword.get(configured, :signal)),
           path when is_binary(path) and path != "" <- Keyword.get(configured, :auth_policy_path),
           false <- Map.has_key?(planes, signal),
           path = Path.expand(path),
           false <- MapSet.member?(paths, path) do
        plane = %{
          signal: signal,
          policy_path: path,
          tenant: to_string(Keyword.get(configured, :tenant, "default"))
        }

        {:cont, {:ok, Map.put(planes, signal, plane), MapSet.put(paths, path)}}
      else
        :disabled -> {:cont, {:ok, planes, paths}}
        true -> {:halt, {:error, :duplicate_telemetry_authorization_owner}}
        nil -> {:halt, {:error, :missing_telemetry_authorization_policy_path}}
        {:error, reason} -> {:halt, {:error, reason}}
        _ -> {:halt, {:error, :invalid_telemetry_authorization_configuration}}
      end
    end)
    |> case do
      {:ok, planes, _paths} when map_size(planes) > 0 -> {:ok, planes}
      {:ok, _planes, _paths} -> {:error, :no_required_telemetry_authorization_planes}
      {:error, _reason} = error -> error
    end
  rescue
    KeyError -> {:error, :missing_telemetry_authorization_planes}
  end

  defp fetch_plane(planes, signal) do
    case Map.fetch(planes, signal) do
      {:ok, plane} -> {:ok, plane}
      :error -> {:error, {:unknown_data_plane, signal}}
    end
  end

  defp normalize_signal(signal) when signal in [:metrics, :logs, :traces], do: {:ok, signal}
  defp normalize_signal("metrics"), do: {:ok, :metrics}
  defp normalize_signal("logs"), do: {:ok, :logs}
  defp normalize_signal("traces"), do: {:ok, :traces}
  defp normalize_signal(signal), do: {:error, {:unsupported_data_plane_signal, signal}}

  defp normalize_options(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_options(opts) when is_list(opts), do: opts
end
