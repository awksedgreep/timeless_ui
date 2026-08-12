defmodule TimelessUI.TelemetryDataPlane.Process do
  @moduledoc """
  Neutral OTP owner for one signal-specific Rust data-plane executable.

  The configured release-startup module completes detection or migration
  before the executable is spawned. The Rust child is the sole database
  owner; this process owns only startup coordination, the OS process, and
  readiness state.
  """

  use GenServer

  require Logger

  @signals %{
    metrics: %{port: 19_439, ready: "timeless-metrics-api listening on "},
    logs: %{port: 19_449, ready: "timeless-logs-api listening on "},
    traces: %{port: 19_459, ready: "timeless-traces-api listening on "}
  }
  @shutdown_timeout 8_000

  def child_spec(opts) do
    signal = option(opts, :signal, :unknown)
    name = option(opts, :name, default_name(signal))

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]},
      restart: option(opts, :restart, :permanent),
      shutdown: 10_000
    }
  end

  def start_link(opts) do
    opts = normalize_options(opts)
    signal = Keyword.get(opts, :signal)
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, default_name(signal)))
  end

  @doc "Wait for migration and the Rust listener to become ready."
  def await_ready(server, timeout \\ 10_000), do: GenServer.call(server, :await_ready, timeout)

  def endpoint(server), do: GenServer.call(server, :endpoint)
  def os_pid(server), do: GenServer.call(server, :os_pid)
  def ready?(server), do: GenServer.call(server, :ready?)
  def status(server), do: GenServer.call(server, :status)
  def retry(server), do: GenServer.call(server, :retry)

  @doc "Fetch a short-lived internal authorization header without logging it."
  def authorization_header(server), do: GenServer.call(server, :authorization_header)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, config} <- validate_options(opts) do
      {:ok,
       %{
         config: config,
         port: nil,
         prepare_task: nil,
         endpoint: dial_endpoint(config.listen),
         phase: :starting,
         ready?: false,
         startup: nil,
         error: nil,
         waiters: [],
         partial_line: ""
       }, {:continue, :prepare}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:prepare, state), do: {:noreply, begin_prepare(state)}

  @impl true
  def handle_call(:await_ready, _from, %{ready?: true} = state) do
    {:reply, {:ok, state.endpoint}, state}
  end

  def handle_call(:await_ready, _from, %{phase: :failed} = state) do
    {:reply, {:error, state.error}, state}
  end

  def handle_call(:await_ready, from, state) do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  def handle_call(:endpoint, _from, state), do: {:reply, state.endpoint, state}
  def handle_call(:ready?, _from, state), do: {:reply, state.ready?, state}

  def handle_call(:os_pid, _from, state) do
    {:reply, port_os_pid(state.port), state}
  end

  def handle_call(:status, _from, state) do
    migration = startup_stats(state.config)

    report =
      Map.merge(migration, %{
        signal: state.config.signal,
        process_phase: state.phase,
        process_ready: state.ready?,
        endpoint: state.endpoint,
        os_pid: port_os_pid(state.port),
        error: state.error || Map.get(migration, :error)
      })

    {:reply, report, state}
  end

  def handle_call(:authorization_header, _from, %{config: %{token_provider: nil}} = state) do
    result =
      if state.config.auth_env["TIMELESS_AUTH_MODE"] == "disabled",
        do: {:ok, nil},
        else: {:error, :data_plane_token_provider_not_configured}

    {:reply, result, state}
  end

  def handle_call(:authorization_header, _from, state) do
    result = invoke_provider(state.config.token_provider, state.config.signal)
    {:reply, result, state}
  end

  def handle_call(:retry, _from, %{phase: :failed} = state) do
    {:reply, :ok, begin_prepare(%{state | error: nil, startup: nil})}
  end

  def handle_call(:retry, _from, state), do: {:reply, {:error, {:not_failed, state.phase}}, state}

  @impl true
  def handle_info(
        {:startup_result, pid, result},
        %{prepare_task: %{pid: pid, ref: reference}} = state
      ) do
    Process.demonitor(reference, [:flush])
    {:noreply, prepare_finished(result, %{state | prepare_task: nil})}
  end

  def handle_info(
        {:DOWN, reference, :process, _pid, reason},
        %{prepare_task: %{ref: reference}} = state
      ) do
    {:noreply,
     fail_waiters(%{state | prepare_task: nil}, {:startup_task_exit, sanitize_reason(reason)})}
  end

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    line = state.partial_line <> line
    {:noreply, consume_line(line, %{state | partial_line: ""})}
  end

  def handle_info({port, {:data, {:noeol, line}}}, %{port: port} = state) do
    {:noreply, %{state | partial_line: state.partial_line <> line}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, {:data_plane_exit, state.config.signal, status}, state}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    {:stop, {:data_plane_port_exit, state.config.signal, reason}, state}
  end

  @impl true
  def terminate(_reason, state) do
    stop_prepare_task(state.prepare_task)
    stop_os_process(state.port, state.config.kill_executable)
    :ok
  catch
    :error, :badarg -> :ok
  end

  defp begin_prepare(state) do
    config = state.config
    owner = self()

    {pid, reference} =
      spawn_monitor(fn ->
        result = apply(config.startup_module, :prepare, [config.data_dir, config.startup_opts])
        send(owner, {:startup_result, self(), result})
      end)

    %{state | phase: :migrating, ready?: false, prepare_task: %{pid: pid, ref: reference}}
  end

  defp prepare_finished({:ok, %{ready: true, target_path: target_path} = startup}, state)
       when is_binary(target_path) do
    target_path = Path.expand(target_path)

    if File.regular?(target_path) do
      case open_port(state.config, target_path) do
        {:ok, port} ->
          %{state | port: port, phase: :binding, startup: startup, error: nil}

        {:error, reason} ->
          fail_waiters(state, reason)
      end
    else
      fail_waiters(state, {:startup_returned_invalid_target, target_path})
    end
  end

  defp prepare_finished({:error, error}, state), do: fail_waiters(state, sanitize_reason(error))

  defp prepare_finished(other, state),
    do: fail_waiters(state, {:invalid_startup_result, sanitize_reason(other)})

  defp fail_waiters(state, reason) do
    Enum.each(state.waiters, &GenServer.reply(&1, {:error, reason}))
    %{state | phase: :failed, ready?: false, error: reason, waiters: []}
  end

  defp consume_line(line, state) do
    if String.starts_with?(line, state.config.ready_prefix) do
      Enum.each(state.waiters, &GenServer.reply(&1, {:ok, state.endpoint}))
      %{state | phase: :ready, ready?: true, waiters: [], error: nil}
    else
      Logger.debug(fn -> "#{state.config.signal} data plane: #{sanitize_line(line)}" end)
      state
    end
  end

  defp validate_options(opts) do
    with {:ok, signal} <- signal(Keyword.get(opts, :signal)),
         {:ok, binary} <- required_path(opts, :binary, signal),
         {:ok, extension} <- required_path(opts, :extension, signal),
         {:ok, data_dir} <- required_option(opts, :data_dir, signal),
         {:ok, startup_module} <- startup_module(opts, signal),
         {:ok, listen} <-
           loopback_listener(
             Keyword.get(opts, :listen, "127.0.0.1:#{@signals[signal].port}"),
             signal,
             Keyword.get(opts, :allow_non_loopback, false)
           ),
         {:ok, auth} <- auth_options(opts, signal),
         {:ok, kill_executable} <- shutdown_executable(signal) do
      startup_opts =
        opts
        |> Keyword.get(:startup_opts, [])
        |> Keyword.put(:extension_path, extension)

      {:ok,
       %{
         signal: signal,
         binary: binary,
         extension: extension,
         data_dir: Path.expand(to_string(data_dir)),
         startup_module: startup_module,
         startup_opts: startup_opts,
         listen: listen,
         ready_prefix: @signals[signal].ready,
         kill_executable: kill_executable,
         env: Keyword.get(opts, :env, %{}),
         auth_env: auth.env,
         token_provider: auth.token_provider
       }}
    end
  end

  defp signal(signal) when is_atom(signal) and is_map_key(@signals, signal), do: {:ok, signal}
  defp signal(signal), do: {:error, {:unsupported_data_plane_signal, signal}}

  defp startup_module(opts, signal) do
    case Keyword.fetch(opts, :startup_module) do
      {:ok, module} when is_atom(module) ->
        if Code.ensure_loaded?(module) and function_exported?(module, :prepare, 2) and
             function_exported?(module, :stats, 2) do
          {:ok, module}
        else
          {:error, {:invalid_data_plane_startup_module, signal, module}}
        end

      _ ->
        {:error, {:missing_data_plane_option, signal, :startup_module}}
    end
  end

  defp auth_options(opts, signal) do
    case Keyword.get(opts, :auth_mode, :disabled) do
      :disabled ->
        {:ok, %{env: %{"TIMELESS_AUTH_MODE" => "disabled"}, token_provider: nil}}

      :required ->
        with {:ok, configured_path} <- required_option(opts, :auth_policy_path, signal) do
          path = Path.expand(to_string(configured_path))

          if File.regular?(path) do
            {:ok,
             %{
               env: %{
                 "TIMELESS_AUTH_MODE" => "required",
                 "TIMELESS_AUTH_POLICY_FILE" => path,
                 "TIMELESS_TENANT" => to_string(Keyword.get(opts, :tenant, "default"))
               },
               token_provider: Keyword.get(opts, :token_provider)
             }}
          else
            {:error, {:invalid_data_plane_auth_policy, signal, path}}
          end
        end

      mode ->
        {:error, {:invalid_data_plane_auth_mode, signal, mode}}
    end
  end

  defp required_path(opts, name, signal) do
    with {:ok, path} <- required_option(opts, name, signal) do
      path = Path.expand(to_string(path))

      case File.stat(path) do
        {:ok, %{type: :regular, mode: mode}} ->
          if name != :binary or Bitwise.band(mode, 0o111) != 0,
            do: {:ok, path},
            else: {:error, {:invalid_data_plane_path, signal, name, path}}

        _ ->
          {:error, {:invalid_data_plane_path, signal, name, path}}
      end
    end
  end

  defp required_option(opts, name, signal) do
    case Keyword.fetch(opts, name) do
      {:ok, value} when value not in [nil, ""] -> {:ok, value}
      _ -> {:error, {:missing_data_plane_option, signal, name}}
    end
  end

  @doc """
  The URL clients dial for a data plane listening on `listen`. A bind
  address is not a destination: a server bound to all interfaces
  (`0.0.0.0`/`::`) is still a local child of this supervisor, and clients
  reach it over loopback. Passing the bind string through verbatim gave
  containers (which must bind `0.0.0.0`) an endpoint every client's
  loopback guard rejected — target sync and queries failed with
  `*_must_use_loopback` on exactly the primary deployment path.
  """
  def dial_endpoint(listen) do
    cond do
      String.starts_with?(listen, "0.0.0.0:") ->
        "http://127.0.0.1:" <> String.trim_leading(listen, "0.0.0.0:")

      String.starts_with?(listen, "[::]:") ->
        "http://[::1]:" <> String.trim_leading(listen, "[::]:")

      true ->
        "http://#{listen}"
    end
  end

  defp loopback_listener(listen, signal, allow_non_loopback) when is_binary(listen) do
    with [host, port_text] <- String.split(listen, ":", parts: 2),
         {:ok, address} <- :inet.parse_address(String.to_charlist(host)),
         true <- allow_non_loopback or loopback_address?(address),
         {port, ""} when port in 1..65_535 <- Integer.parse(port_text) do
      {:ok, "#{host}:#{port}"}
    else
      _ -> {:error, {:data_plane_must_use_loopback, signal, listen}}
    end
  end

  defp loopback_listener(listen, signal, _allow_non_loopback),
    do: {:error, {:data_plane_must_use_loopback, signal, listen}}

  defp loopback_address?({127, _, _, _}), do: true
  defp loopback_address?(_address), do: false

  defp shutdown_executable(signal) do
    case System.find_executable("kill") do
      nil -> {:error, {:data_plane_requires_kill_executable, signal}}
      executable -> {:ok, executable}
    end
  end

  defp open_port(config, database) do
    args = Enum.map([config.extension, database, config.listen], &String.to_charlist/1)
    environment = Map.merge(stringify_env(config.env), config.auth_env)

    port_options = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:line, 4_096},
      {:args, args},
      {:env, port_environment(environment)}
    ]

    {:ok, Port.open({:spawn_executable, String.to_charlist(config.binary)}, port_options)}
  rescue
    error in [ArgumentError, ErlangError] ->
      {:error, {:start_data_plane, config.signal, sanitize_reason(error)}}
  end

  defp startup_stats(config) do
    case apply(config.startup_module, :stats, [config.data_dir, config.startup_opts]) do
      stats when is_map(stats) -> stats
      {:ok, stats} when is_map(stats) -> stats
      other -> %{migration_stats_error: sanitize_reason(other)}
    end
  rescue
    error -> %{migration_stats_error: Exception.message(error)}
  catch
    kind, reason -> %{migration_stats_error: {kind, sanitize_reason(reason)}}
  end

  defp invoke_provider({module, function, arguments}, signal)
       when is_atom(module) and is_atom(function) and is_list(arguments) do
    apply(module, function, [signal | arguments])
  rescue
    error -> {:error, {:data_plane_token_provider_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:data_plane_token_provider_failed, kind, sanitize_reason(reason)}}
  end

  defp invoke_provider(_, _signal), do: {:error, :invalid_data_plane_token_provider}

  defp stop_prepare_task(nil), do: :ok

  defp stop_prepare_task(%{pid: pid, ref: reference}) do
    Process.demonitor(reference, [:flush])
    Process.exit(pid, :kill)
  end

  defp stop_os_process(nil, _kill_executable), do: :ok

  defp stop_os_process(port, kill_executable) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        signal_os_process(kill_executable, os_pid, "-TERM")

        receive do
          {^port, {:exit_status, _status}} -> :ok
          {:EXIT, ^port, _reason} -> :ok
        after
          @shutdown_timeout ->
            signal_os_process(kill_executable, os_pid, "-KILL")

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

  defp signal_os_process(executable, os_pid, signal) do
    System.cmd(executable, [signal, Integer.to_string(os_pid)])
  end

  defp close_port(port) do
    if Port.info(port) != nil, do: Port.close(port)
  end

  defp port_os_pid(nil), do: nil

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end

  defp port_environment(environment) do
    Enum.map(environment, fn {name, value} ->
      {name |> to_string() |> String.to_charlist(), value |> to_string() |> String.to_charlist()}
    end)
  end

  defp stringify_env(environment) when is_map(environment) do
    Map.new(environment, fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  defp stringify_env(environment) when is_list(environment) do
    Map.new(environment, fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  defp sanitize_line(line) do
    line = Regex.replace(~r/(?i)\bbearer\s+\S+/, line, "Bearer [REDACTED]")

    Regex.replace(
      ~r/(?i)\b(authorization|token|secret|private[_ -]?key)\b\s*[:=]\s*\S+/,
      line,
      "\\1=[REDACTED]"
    )
  end

  defp sanitize_reason(%{__struct__: module}), do: module

  defp sanitize_reason(reason) when is_map(reason),
    do: Map.new(reason, fn {key, value} -> {key, sanitize_reason(value)} end)

  defp sanitize_reason(reason) when is_list(reason), do: Enum.map(reason, &sanitize_reason/1)

  defp sanitize_reason(reason) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> Enum.map(&sanitize_reason/1) |> List.to_tuple()

  defp sanitize_reason(reason) when is_binary(reason), do: sanitize_line(reason)
  defp sanitize_reason(reason), do: reason

  defp normalize_options(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_options(opts) when is_list(opts), do: opts

  defp default_name(:metrics), do: TimelessUI.MetricsDataPlane.Process
  defp default_name(:logs), do: TimelessUI.LogsDataPlane.Process
  defp default_name(:traces), do: TimelessUI.TracesDataPlane.Process
  defp default_name(_), do: __MODULE__

  defp option(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)
  defp option(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
end
