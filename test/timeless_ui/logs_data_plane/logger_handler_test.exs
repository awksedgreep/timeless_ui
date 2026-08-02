defmodule TimelessUI.LogsDataPlane.LoggerHandlerTest do
  use ExUnit.Case, async: true

  alias TimelessUI.LogsDataPlane.{Buffer, LoggerHandler}

  test "nested JSON-compatible Logger metadata keeps exact value types" do
    name = {:global, {:typed_logs_buffer, System.unique_integer([:positive])}}

    start_supervised!(
      {Buffer,
       name: name,
       client: TimelessUI.LogsDataPlaneBufferClientFixture,
       client_opts: [notify: self()],
       install_logger: false,
       flush_interval: 60_000}
    )

    event = %{
      level: :error,
      msg: {:string, "typed"},
      meta: %{
        time: 1_785_672_000_123_456,
        count: 7,
        ratio: 2.5,
        retryable: true,
        missing: nil,
        nested: %{attempts: [1, 2], state: :open}
      }
    }

    assert :ok = LoggerHandler.log(event, %{config: %{buffer: name}})
    assert :ok = Buffer.flush(name)
    assert_receive {:logs_ingest, [entry]}

    assert entry.metadata == %{
             "count" => 7,
             "ratio" => 2.5,
             "retryable" => true,
             "missing" => nil,
             "nested" => %{"attempts" => [1, 2], "state" => "open"}
           }
  end
end
