defmodule TimelessUI.TelemetryDataPlane.ProcessTest do
  use ExUnit.Case, async: false

  alias TimelessUI.TelemetryDataPlane.Process, as: DataPlaneProcess
  alias TimelessUI.TelemetryDataPlaneStartupFixture, as: Startup

  setup do
    root =
      Path.join(System.tmp_dir!(), "timeless-data-plane-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    extension = Path.join(root, "libtimeless_ext.so")
    executable = Path.join(root, "data-plane-fixture")
    File.write!(extension, "fixture")

    File.write!(
      executable,
      "#!/bin/sh\ntrap 'exit 0' TERM INT\necho \"${TEST_READY_PREFIX}$3\"\nwhile :; do read -r line || sleep 1; done\n"
    )

    File.chmod!(executable, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, extension: extension, executable: executable}
  end

  test "all three signal owners prepare before spawn and expose bounded status", fixture do
    processes =
      for signal <- [:metrics, :logs, :traces], into: %{} do
        name = {:global, {:data_plane_test, signal, System.unique_integer([:positive])}}

        opts =
          base_options(fixture, signal, name,
            data_dir: Path.join(fixture.root, Atom.to_string(signal))
          )

        start_supervised!({DataPlaneProcess, opts})
        assert {:ok, endpoint} = DataPlaneProcess.await_ready(name)
        assert String.starts_with?(endpoint, "http://127.0.0.1:")

        status = DataPlaneProcess.status(name)
        assert status.signal == signal
        assert status.process_phase == :ready
        assert status.process_ready
        assert status.state == :valid_libsql
        assert status.completed_records == status.records_total
        refute Map.has_key?(status, :env)
        refute inspect(status) =~ "Bearer "

        {signal, %{name: name, pid: GenServer.whereis(name), os_pid: status.os_pid}}
      end

    assert Enum.all?(processes, fn {_signal, owner} -> is_pid(owner.pid) end)
    assert Enum.all?(processes, fn {_signal, owner} -> is_integer(owner.os_pid) end)
    assert processes.metrics.os_pid != processes.logs.os_pid
    assert processes.logs.os_pid != processes.traces.os_pid
  end

  test "a closed migration failure never spawns Rust and can be retried", fixture do
    name = :failed_data_plane_fixture

    start_supervised!(
      {DataPlaneProcess,
       base_options(fixture, :logs, name,
         data_dir: Path.join(fixture.root, "failed"),
         startup_opts: [fixture_result: {:error, "corrupt source token=must-not-leak"}]
       )}
    )

    assert {:error, %{state: :corruption}} = DataPlaneProcess.await_ready(name)
    refute DataPlaneProcess.ready?(name)
    assert DataPlaneProcess.os_pid(name) == nil

    status = DataPlaneProcess.status(name)
    assert status.process_phase == :failed
    refute inspect(status) =~ "must-not-leak"
    assert inspect(status) =~ "[REDACTED]"
    assert :ok = DataPlaneProcess.retry(name)
    assert {:error, %{state: :corruption}} = DataPlaneProcess.await_ready(name)
  end

  test "an explicit container bind permits non-loopback listeners", fixture do
    name = :container_bind_fixture

    opts =
      base_options(fixture, :metrics, name,
        listen: "0.0.0.0:#{free_port()}",
        data_dir: Path.join(fixture.root, "container-bind"),
        allow_non_loopback: true
      )

    start_supervised!({DataPlaneProcess, opts})
    assert {:ok, "http://0.0.0.0:" <> _} = DataPlaneProcess.await_ready(name)
  end

  test "abnormal child death restarts while normal shutdown drains and reaps", fixture do
    name = :restarting_data_plane_fixture
    opts = base_options(fixture, :traces, name, data_dir: Path.join(fixture.root, "restart"))
    start_supervised!({DataPlaneProcess, opts})
    assert {:ok, _endpoint} = DataPlaneProcess.await_ready(name)

    old_owner = GenServer.whereis(name)
    old_ref = Process.monitor(old_owner)
    old_os_pid = DataPlaneProcess.os_pid(name)
    assert {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(old_os_pid)])
    assert_receive {:DOWN, ^old_ref, :process, ^old_owner, _reason}, 5_000

    new_owner = await_restarted(name, old_owner, 500)
    assert is_pid(new_owner)
    assert {:ok, _endpoint} = DataPlaneProcess.await_ready(name)
    new_os_pid = DataPlaneProcess.os_pid(name)
    assert new_os_pid != old_os_pid

    assert :ok = stop_supervised({DataPlaneProcess, name})
    assert :ok = await_os_process_down(new_os_pid, 500)
  end

  test "required authorization is preflighted before migration", fixture do
    name = :missing_policy_data_plane_fixture

    assert {:error, reason} =
             GenServer.start(
               DataPlaneProcess,
               base_options(fixture, :metrics, name,
                 data_dir: Path.join(fixture.root, "auth"),
                 auth_mode: :required,
                 auth_policy_path: Path.join(fixture.root, "missing-policy.json")
               )
             )

    assert inspect(reason) =~ "invalid_data_plane_auth_policy"
    refute File.exists?(Path.join(fixture.root, "auth"))
  end

  test "a non-executable release binary fails before touching storage", fixture do
    File.chmod!(fixture.executable, 0o600)
    data_dir = Path.join(fixture.root, "must-remain-absent")

    assert {:error, reason} =
             GenServer.start(
               DataPlaneProcess,
               base_options(fixture, :logs, :non_executable_fixture, data_dir: data_dir)
             )

    assert inspect(reason) =~ "invalid_data_plane_path"
    assert inspect(reason) =~ "binary"
    refute File.exists?(data_dir)
  end

  defp base_options(fixture, signal, name, overrides) do
    [
      signal: signal,
      name: name,
      binary: fixture.executable,
      extension: fixture.extension,
      startup_module: Startup,
      listen: "127.0.0.1:#{free_port()}",
      auth_mode: :disabled,
      env: %{"TEST_READY_PREFIX" => ready_prefix(signal)}
    ]
    |> Keyword.merge(overrides)
  end

  defp ready_prefix(:metrics), do: "timeless-metrics-api listening on "
  defp ready_prefix(:logs), do: "timeless-logs-api listening on "
  defp ready_prefix(:traces), do: "timeless-traces-api listening on "

  defp await_restarted(_name, _old_pid, 0), do: nil

  defp await_restarted(name, old_pid, attempts) do
    case GenServer.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        receive do
        after
          10 -> await_restarted(name, old_pid, attempts - 1)
        end
    end
  end

  defp free_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  defp await_os_process_down(_os_pid, 0), do: {:error, :still_running}

  defp await_os_process_down(os_pid, attempts) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_output, status} when status != 0 ->
        :ok

      _ ->
        receive do
        after
          10 -> await_os_process_down(os_pid, attempts - 1)
        end
    end
  end
end
