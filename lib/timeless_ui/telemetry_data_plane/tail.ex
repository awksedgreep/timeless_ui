defmodule TimelessUI.TelemetryDataPlane.Tail do
  @moduledoc false

  @supervisor TimelessUI.TelemetryTailSupervisor
  @max_line_bytes 1_048_576

  def start(subscriber, request) when is_pid(subscriber) and is_function(request, 0) do
    Task.Supervisor.start_child(@supervisor, fn -> supervise_request(subscriber, request) end)
  end

  def split_lines(buffer, chunk, max_line_bytes \\ @max_line_bytes)
      when is_binary(buffer) and is_binary(chunk) do
    do_split_lines(buffer <> chunk, max_line_bytes, [])
  end

  defp supervise_request(subscriber, request) do
    Process.flag(:trap_exit, true)
    subscriber_ref = Process.monitor(subscriber)
    request_pid = spawn_link(request)

    receive do
      {:DOWN, ^subscriber_ref, :process, ^subscriber, _reason} ->
        Process.exit(request_pid, :shutdown)
        await_request_exit(request_pid)

      {:EXIT, ^request_pid, _reason} ->
        Process.demonitor(subscriber_ref, [:flush])
        :ok
    end
  end

  defp await_request_exit(request_pid) do
    receive do
      {:EXIT, ^request_pid, _reason} -> :ok
    after
      1_000 -> Process.exit(request_pid, :kill)
    end
  end

  defp do_split_lines(data, max_line_bytes, lines) do
    case :binary.match(data, "\n") do
      {index, 1} when index <= max_line_bytes ->
        line = binary_part(data, 0, index)
        rest = binary_part(data, index + 1, byte_size(data) - index - 1)
        lines = if line == "", do: lines, else: [line | lines]
        do_split_lines(rest, max_line_bytes, lines)

      {_index, 1} ->
        {:error, :line_too_large}

      :nomatch when byte_size(data) <= max_line_bytes ->
        {:ok, Enum.reverse(lines), data}

      :nomatch ->
        {:error, :line_too_large}
    end
  end
end
