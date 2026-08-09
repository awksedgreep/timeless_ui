alias TimelessUI.MetricsDataPlane.Client
alias TimelessUI.MetricsDataPlane.Process, as: DataPlaneProcess

defmodule MetricsDataPlaneBoundaryBench do
  @iterations 500
  @rounds 5

  def run do
    workspace = Path.expand("../..", __DIR__)
    libsql = Path.join(workspace, "timeless-libsql")

    binary =
      System.get_env("TIMELESS_METRICS_API_BINARY") ||
        Path.join(libsql, "servers/target/release/timeless-metrics-api")

    extension =
      System.get_env("TIMELESS_LIBSQL_EXTENSION") ||
        Path.join(libsql, "target/release/libtimeless_ext.so")

    for path <- [binary, extension] do
      unless File.regular?(path), do: raise("missing release artifact: #{path}")
    end

    Application.ensure_all_started(:req)

    unique = System.unique_integer([:positive])
    name = :"metrics_data_plane_bench_#{unique}"
    database = Path.join(System.tmp_dir!(), "metrics_data_plane_bench_#{unique}.db")
    port = free_port()

    {:ok, supervisor} =
      Supervisor.start_link(
        [
          {DataPlaneProcess,
           name: name,
           binary: binary,
           extension: extension,
           database: database,
           listen: "127.0.0.1:#{port}",
           env: %{
             "TIMELESS_METRICS_FLUSH_INTERVAL_SECS" => "3600",
             "TIMELESS_METRICS_COMPACT_INTERVAL_SECS" => "3600",
             "TIMELESS_METRICS_RETENTION_INTERVAL_SECS" => "3600"
           }}
        ],
        strategy: :one_for_one
      )

    try do
      {:ok, endpoint} = DataPlaneProcess.await_ready(name)
      base = 1_728_000_000

      body =
        Enum.map_join(0..599, "\n", fn offset ->
          "canvas_boundary{host=\"edge\"} #{offset / 10} #{(base + offset) * 1_000}"
        end)

      :ok = Client.import_prometheus(body, process: name)
      {:ok, _flush} = Client.flush(process: name)

      query = fn opts ->
        {:ok, [_series]} =
          Client.export("canvas_boundary", %{"host" => "edge"}, base, base + 599, opts)
      end

      Enum.each(1..50, fn _ ->
        query.(base_url: endpoint)
        query.(process: name)
      end)

      {direct, supervised} =
        Enum.reduce(1..@rounds, {[], []}, fn _round, {direct, supervised} ->
          {round_direct, round_supervised} = paired_samples(query, endpoint, name)
          {round_direct ++ direct, round_supervised ++ supervised}
        end)

      old_pid = Process.whereis(name)
      ref = Process.monitor(old_pid)
      os_pid = DataPlaneProcess.os_pid(name)
      restart_started = System.monotonic_time(:microsecond)
      {_output, 0} = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])

      receive do
        {:DOWN, ^ref, :process, ^old_pid, _reason} -> :ok
      after
        5_000 -> raise("timed out waiting for supervised process exit")
      end

      await_restarted(name, old_pid, 500)
      {:ok, ^endpoint} = DataPlaneProcess.await_ready(name)
      restart_us = System.monotonic_time(:microsecond) - restart_started
      query.(process: name)

      direct_p95 = percentile(direct, 0.95)
      supervised_p95 = percentile(supervised, 0.95)

      IO.puts(
        "rounds=#{@rounds} iterations_per_round=#{@iterations} " <>
          "samples_per_path=#{length(direct)} points_per_response=600"
      )

      IO.puts("base_url_client_p50_us=#{percentile(direct, 0.50)}")
      IO.puts("base_url_client_p95_us=#{direct_p95}")
      IO.puts("base_url_client_p99_us=#{percentile(direct, 0.99)}")
      IO.puts("supervised_client_p50_us=#{percentile(supervised, 0.50)}")
      IO.puts("supervised_client_p95_us=#{supervised_p95}")
      IO.puts("supervised_client_p99_us=#{percentile(supervised, 0.99)}")
      IO.puts("supervision_lookup_p95_delta_us=#{supervised_p95 - direct_p95}")
      IO.puts("sigkill_to_ready_us=#{restart_us}")
      IO.puts("reopen_query=exact")
    after
      Supervisor.stop(supervisor)

      for suffix <- ["", "-shm", "-wal", ".timeless-metrics-api.lock"] do
        File.rm(database <> suffix)
      end
    end
  end

  defp paired_samples(query, endpoint, name) do
    Enum.reduce(1..@iterations, {[], []}, fn iteration, {direct, supervised} ->
      operations =
        if rem(iteration, 2) == 0 do
          [direct: [base_url: endpoint], supervised: [process: name]]
        else
          [supervised: [process: name], direct: [base_url: endpoint]]
        end

      timings =
        Enum.map(operations, fn {kind, opts} ->
          started = System.monotonic_time(:microsecond)
          query.(opts)
          {kind, System.monotonic_time(:microsecond) - started}
        end)

      {
        [Keyword.fetch!(timings, :direct) | direct],
        [Keyword.fetch!(timings, :supervised) | supervised]
      }
    end)
  end

  defp percentile(samples, quantile) do
    sorted = Enum.sort(samples)
    index = max(ceil(length(sorted) * quantile) - 1, 0)
    Enum.at(sorted, index)
  end

  defp free_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  defp await_restarted(_name, _old_pid, 0), do: raise("data plane did not restart")

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
end

MetricsDataPlaneBoundaryBench.run()
