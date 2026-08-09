defmodule TimelessUI.LogsDataPlane.BufferTest do
  use ExUnit.Case, async: true

  alias TimelessUI.LogsDataPlane.Buffer

  test "flushes one complete transport batch through the public API" do
    buffer = start_buffer(notify: self())
    assert :ok = Buffer.log(buffer, entry(1))
    assert :ok = Buffer.log(buffer, entry(2))
    assert :ok = Buffer.flush(buffer)

    assert_receive {:logs_ingest, [first, second]}
    assert first.message == "event-1"
    assert second.message == "event-2"

    assert %{admitted: 2, completed: 2, count: 0, failed_flushes: 0, max_entries: 256} =
             Buffer.stats(buffer)
  end

  test "flushes a bounded transport batch without claiming storage ownership" do
    buffer = start_buffer(notify: self())

    Enum.each(1..257, fn id -> assert :ok = Buffer.log(buffer, entry(id)) end)

    assert_receive {:logs_ingest, entries}
    assert length(entries) == 256
    assert %{admitted: 257, completed: 256, count: 1, max_entries: 256} = Buffer.stats(buffer)
  end

  test "a failed flush retains the complete batch and reports the failure" do
    buffer = start_buffer(result: {:error, :closed})
    assert :ok = Buffer.log(buffer, entry(1))
    assert {:error, {:incomplete_logs_transport_flush, {:error, :closed}}} = Buffer.flush(buffer)
    assert %{admitted: 1, completed: 0, count: 1, failed_flushes: 1} = Buffer.stats(buffer)
  end

  test "supervisor shutdown drains the admitted tail before the Rust owner stops" do
    name = {:global, {:draining_logs_buffer, System.unique_integer([:positive])}}

    start_supervised!(
      {Buffer,
       name: name,
       client: TimelessUI.LogsDataPlaneBufferClientFixture,
       client_opts: [notify: self()],
       install_logger: false,
       flush_interval: 60_000}
    )

    assert :ok = Buffer.log(name, entry(1))
    assert :ok = stop_supervised(Buffer)
    assert_receive {:logs_ingest, [%{message: "event-1"}]}
  end

  defp start_buffer(client_opts) do
    name = {:global, {:logs_buffer, System.unique_integer([:positive])}}

    start_supervised!(
      {Buffer,
       name: name,
       client: TimelessUI.LogsDataPlaneBufferClientFixture,
       client_opts: client_opts,
       install_logger: false,
       flush_interval: 60_000}
    )

    name
  end

  defp entry(id) do
    %{timestamp: id, level: :info, message: "event-#{id}", metadata: %{"id" => id}}
  end
end
