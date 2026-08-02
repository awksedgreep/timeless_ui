defmodule TimelessUI.MetricsDataPlane.Process do
  @moduledoc """
  Supervises the standalone Rust metrics data-plane executable through an OTP port.

  The child process, rather than the BEAM, exclusively owns the telemetry database.
  This process owns only the operating-system child and its readiness state.
  """

  use GenServer

  require Logger

  @default_name __MODULE__
  @ready_prefix "timeless-metrics-api listening on "
  @shutdown_timeout 8_000

  def child_spec(opts) do
    %{
      id: {__MODULE__, option(opts, :name, @default_name)},
      start: {__MODULE__, :start_link, [opts]},
      restart: option(opts, :restart, :permanent),
      shutdown: 10_000
    }
  end

  def start_link(opts) do
    opts = normalize_options(opts)
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @default_name))
  end

  @doc "Wait until the Rust server has bound its listener."
  def await_ready(server \\ @default_name, timeout \\ 10_000) do
    GenServer.call(server, :await_ready, timeout)
  end

  @doc "Return the loopback HTTP endpoint configured for the child."
  def endpoint(server \\ @default_name), do: GenServer.call(server, :endpoint)

  @doc "Return the operating-system pid of the current Rust child."
  def os_pid(server \\ @default_name), do: GenServer.call(server, :os_pid)

  @doc false
  def ready?(server \\ @default_name), do: GenServer.call(server, :ready?)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, config} <- validate_options(opts),
         {:ok, port} <- open_port(config) do
      {:ok,
       %{
         port: port,
         endpoint: "http://#{config.listen}",
         kill_executable: config.kill_executable,
         ready?: false,
         waiters: [],
         partial_line: ""
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:await_ready, _from, %{ready?: true} = state) do
    {:reply, {:ok, state.endpoint}, state}
  end

  def handle_call(:await_ready, from, state) do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  def handle_call(:endpoint, _from, state), do: {:reply, state.endpoint, state}
  def handle_call(:ready?, _from, state), do: {:reply, state.ready?, state}

  def handle_call(:os_pid, _from, state) do
    pid =
      case Port.info(state.port, :os_pid) do
        {:os_pid, pid} -> pid
        nil -> nil
      end

    {:reply, pid, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    line = state.partial_line <> line
    {:noreply, consume_line(line, %{state | partial_line: ""})}
  end

  def handle_info({port, {:data, {:noeol, line}}}, %{port: port} = state) do
    {:noreply, %{state | partial_line: state.partial_line <> line}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, {:metrics_data_plane_exit, status}, state}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    {:stop, {:metrics_data_plane_port_exit, reason}, state}
  end

  @impl true
  def terminate(_reason, %{port: port, kill_executable: kill_executable}) do
    if Port.info(port) != nil do
      stop_os_process(port, kill_executable)
    end

    :ok
  catch
    :error, :badarg -> :ok
  end

  defp stop_os_process(port, kill_executable) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        signal(kill_executable, os_pid, "-TERM")

        receive do
          {^port, {:exit_status, _status}} -> :ok
          {:EXIT, ^port, _reason} -> :ok
        after
          @shutdown_timeout ->
            signal(kill_executable, os_pid, "-KILL")

            receive do
              {^port, {:exit_status, _status}} -> :ok
              {:EXIT, ^port, _reason} -> :ok
            after
              1_000 -> close_port(port)
            end
        end

      nil ->
        :ok
    end
  end

  defp signal(executable, os_pid, signal) do
    System.cmd(executable, [signal, Integer.to_string(os_pid)])
  end

  defp close_port(port) do
    if Port.info(port) != nil, do: Port.close(port)
  end

  defp consume_line(line, state) do
    if String.starts_with?(line, @ready_prefix) do
      Enum.each(state.waiters, &GenServer.reply(&1, {:ok, state.endpoint}))
      %{state | ready?: true, waiters: []}
    else
      Logger.debug("metrics data plane: #{line}")
      state
    end
  end

  defp validate_options(opts) do
    with {:ok, binary} <- required_path(opts, :binary),
         {:ok, extension} <- required_path(opts, :extension),
         {:ok, database} <- required_option(opts, :database),
         {:ok, listen} <- loopback_listener(Keyword.get(opts, :listen, "127.0.0.1:19439")),
         {:ok, kill_executable} <- shutdown_executable() do
      {:ok,
       %{
         binary: binary,
         extension: extension,
         database: Path.expand(to_string(database)),
         listen: listen,
         kill_executable: kill_executable,
         env: Keyword.get(opts, :env, %{})
       }}
    end
  end

  defp required_path(opts, name) do
    with {:ok, path} <- required_option(opts, name) do
      path = Path.expand(to_string(path))

      if File.regular?(path) do
        {:ok, path}
      else
        {:error, {:invalid_metrics_data_plane_path, name, path}}
      end
    end
  end

  defp required_option(opts, name) do
    case Keyword.fetch(opts, name) do
      {:ok, value} when value not in [nil, ""] -> {:ok, value}
      _ -> {:error, {:missing_metrics_data_plane_option, name}}
    end
  end

  defp loopback_listener(listen) when is_binary(listen) do
    with [host, port_text] <- String.split(listen, ":", parts: 2),
         {:ok, address} <- :inet.parse_address(String.to_charlist(host)),
         true <- loopback_address?(address),
         {port, ""} when port in 1..65_535 <- Integer.parse(port_text) do
      {:ok, "#{host}:#{port}"}
    else
      _ -> {:error, {:metrics_data_plane_must_use_loopback, listen}}
    end
  end

  defp loopback_listener(listen), do: {:error, {:metrics_data_plane_must_use_loopback, listen}}

  defp loopback_address?({127, _, _, _}), do: true
  defp loopback_address?(_address), do: false

  defp shutdown_executable do
    case System.find_executable("kill") do
      nil -> {:error, :metrics_data_plane_requires_kill_executable}
      executable -> {:ok, executable}
    end
  end

  defp open_port(config) do
    args = Enum.map([config.extension, config.database, config.listen], &String.to_charlist/1)

    port_options = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:line, 4_096},
      {:args, args},
      {:env, port_environment(config.env)}
    ]

    {:ok, Port.open({:spawn_executable, String.to_charlist(config.binary)}, port_options)}
  rescue
    error in [ArgumentError, ErlangError] -> {:error, {:start_metrics_data_plane, error}}
  end

  defp port_environment(environment) do
    Enum.map(environment, fn {name, value} ->
      {name |> to_string() |> String.to_charlist(), value |> to_string() |> String.to_charlist()}
    end)
  end

  defp normalize_options(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_options(opts) when is_list(opts), do: opts

  defp option(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)
  defp option(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
end
