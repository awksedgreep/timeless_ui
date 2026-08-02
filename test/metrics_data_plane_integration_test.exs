defmodule TimelessUI.MetricsDataPlaneIntegrationTest do
  use ExUnit.Case, async: false

  alias TimelessCanvas.Canvas.Element
  alias TimelessUI.MetricsDataPlane.CanvasSource
  alias TimelessUI.MetricsDataPlane.Client
  alias TimelessUI.MetricsDataPlane.Process, as: DataPlaneProcess

  @libsql Path.expand("../../timeless-libsql", __DIR__)
  @binary Path.join(@libsql, "servers/target/release/timeless-metrics-api")
  @extension Path.join(@libsql, "target/release/libtimeless_ext.so")

  if File.regular?(@binary) and File.regular?(@extension) do
    test "supervised Rust crash isolates the BEAM and preserves flushed Canvas results" do
      unique = System.unique_integer([:positive])
      name = :"metrics_data_plane_#{unique}"
      database = Path.join(System.tmp_dir!(), "metrics_data_plane_#{unique}.db")
      port = free_port()

      on_exit(fn ->
        File.rm(database)
        File.rm(database <> "-shm")
        File.rm(database <> "-wal")
        File.rm(database <> ".timeless-metrics-api.lock")
      end)

      process_opts = [
        name: name,
        binary: @binary,
        extension: @extension,
        database: database,
        listen: "127.0.0.1:#{port}",
        env: %{
          "TIMELESS_METRICS_FLUSH_INTERVAL_SECS" => "3600",
          "TIMELESS_METRICS_COMPACT_INTERVAL_SECS" => "3600",
          "TIMELESS_METRICS_RETENTION_INTERVAL_SECS" => "3600"
        }
      ]

      start_supervised!({DataPlaneProcess, process_opts})

      assert {:ok, endpoint} = DataPlaneProcess.await_ready(name)
      assert File.regular?(database <> ".timeless-metrics-api.lock")

      {second_owner_output, second_owner_status} =
        System.cmd(
          @binary,
          [@extension, database, "127.0.0.1:#{free_port()}"],
          stderr_to_stdout: true
        )

      assert second_owner_status != 0
      assert second_owner_output =~ "already owned by another timeless-metrics-api process"

      client_opts = [process: name]
      base_ms = 1_728_000_000_000

      body = """
      canvas_cpu{host="edge",env="test"} 1.5 #{base_ms}
      canvas_cpu{host="edge",env="test"} 2.5 #{base_ms + 1_000}
      """

      assert :ok = Client.import_prometheus(body, client_opts)
      assert {:ok, %{"completed_points" => 2, "queued_batches" => 0}} = Client.flush(client_opts)

      assert {:ok, source} =
               CanvasSource.init(%{
                 client_opts: client_opts,
                 fallback: TimelessCanvas.DataSource.Stub
               })

      element =
        Element.new(%{
          id: "cpu",
          type: :graph,
          meta: %{"metric_name" => "canvas_cpu", "host" => "edge", "env" => "test"}
        })

      from = DateTime.from_unix!(1_728_000_000)
      to = DateTime.from_unix!(1_728_000_001)
      expected = {:ok, [{base_ms, 1.5}, {base_ms + 1_000, 2.5}]}

      assert expected == CanvasSource.metric_range(source, element, "canvas_cpu", from, to)

      old_beam_pid = Process.whereis(name)
      old_ref = Process.monitor(old_beam_pid)
      old_os_pid = DataPlaneProcess.os_pid(name)
      assert is_integer(old_os_pid)
      assert {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(old_os_pid)])
      assert_receive {:DOWN, ^old_ref, :process, ^old_beam_pid, _reason}, 5_000

      new_beam_pid = await_restarted(name, old_beam_pid, 500)
      assert is_pid(new_beam_pid)
      assert {:ok, ^endpoint} = DataPlaneProcess.await_ready(name)
      assert expected == CanvasSource.metric_range(source, element, "canvas_cpu", from, to)
      assert Process.whereis(TimelessUI.Supervisor) != nil

      assert :ok =
               Client.import_prometheus(
                 "canvas_cpu{host=\"edge\",env=\"test\"} 3.5 #{base_ms + 2_000}\n",
                 client_opts
               )

      restarted_os_pid = DataPlaneProcess.os_pid(name)
      assert :ok = stop_supervised({DataPlaneProcess, name})
      assert :ok = await_os_process_down(restarted_os_pid, 500)

      start_supervised!({DataPlaneProcess, process_opts})
      assert {:ok, ^endpoint} = DataPlaneProcess.await_ready(name)

      normal_stop_expected =
        {:ok, [{base_ms, 1.5}, {base_ms + 1_000, 2.5}, {base_ms + 2_000, 3.5}]}

      assert normal_stop_expected ==
               CanvasSource.metric_range(
                 source,
                 element,
                 "canvas_cpu",
                 from,
                 DateTime.from_unix!(1_728_000_002)
               )

      final_os_pid = DataPlaneProcess.os_pid(name)
      assert :ok = stop_supervised({DataPlaneProcess, name})
      assert :ok = await_os_process_down(final_os_pid, 500)
    end
  else
    @tag skip: "build the timeless-libsql extension and release server artifacts to run this gate"
    test "supervised Rust crash isolates the BEAM and preserves flushed Canvas results" do
      :ok
    end
  end

  defp free_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  defp await_restarted(_name, _old_pid, 0), do: nil

  defp await_restarted(name, old_pid, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        receive do
        after
          10 -> await_restarted(name, old_pid, attempts - 1)
        end
    end
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
