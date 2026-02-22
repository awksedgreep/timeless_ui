defmodule TimelessUI.StreamManagerTest do
  use ExUnit.Case

  alias TimelessUI.StreamManager

  defmodule FakeLogBackend do
    @doc "subscribe/1 that blocks forever (mimics real backend)."
    def subscribe(_opts) do
      receive do
        :stop -> :ok
      end
    end
  end

  defmodule FakeTraceBackend do
    def subscribe(_opts) do
      receive do
        :stop -> :ok
      end
    end
  end

  setup do
    # Configure fake backends for this test
    Application.put_env(:timeless_ui, :stream_backends,
      log: FakeLogBackend,
      trace: FakeTraceBackend
    )

    name = :"stream_mgr_#{System.unique_integer([:positive])}"
    {:ok, pid} = StreamManager.start_link(name: name)

    on_exit(fn ->
      Application.delete_env(:timeless_ui, :stream_backends)
    end)

    %{server: name, pid: pid}
  end

  describe "register_log_stream/3" do
    test "registers and returns :ok", %{server: server} do
      assert :ok = StreamManager.register_log_stream("el-1", [], server)
    end

    test "get_buffer returns empty list initially", %{server: server} do
      StreamManager.register_log_stream("el-1", [], server)
      assert [] = StreamManager.get_buffer("el-1", server)
    end
  end

  describe "register_trace_stream/3" do
    test "registers and returns :ok", %{server: server} do
      assert :ok = StreamManager.register_trace_stream("el-2", [], server)
    end

    test "get_buffer returns empty list initially", %{server: server} do
      StreamManager.register_trace_stream("el-2", [], server)
      assert [] = StreamManager.get_buffer("el-2", server)
    end
  end

  describe "no backend configured" do
    setup do
      Application.delete_env(:timeless_ui, :stream_backends)

      name = :"stream_mgr_nobackend_#{System.unique_integer([:positive])}"
      {:ok, pid} = StreamManager.start_link(name: name)
      %{server: name, pid: pid}
    end

    test "register_log_stream is a no-op", %{server: server} do
      assert :ok = StreamManager.register_log_stream("el-1", [], server)
      assert [] = StreamManager.get_buffer("el-1", server)
    end

    test "register_trace_stream is a no-op", %{server: server} do
      assert :ok = StreamManager.register_trace_stream("el-2", [], server)
      assert [] = StreamManager.get_buffer("el-2", server)
    end
  end

  describe "unregister_stream/2" do
    test "unregisters a log stream", %{server: server} do
      StreamManager.register_log_stream("el-1", [], server)
      assert :ok = StreamManager.unregister_stream("el-1", server)
      assert [] = StreamManager.get_buffer("el-1", server)
    end

    test "unregistering non-existent stream returns :ok", %{server: server} do
      assert :ok = StreamManager.unregister_stream("el-999", server)
    end
  end

  describe "buffer management" do
    test "buffers log entries and caps at 50", %{server: server, pid: pid} do
      StreamManager.register_log_stream("el-1", [], server)

      # Simulate 60 log entries arriving
      for i <- 1..60 do
        entry = %{
          timestamp: System.system_time(:millisecond),
          level: :info,
          message: "log #{i}",
          metadata: %{}
        }

        send(pid, {:stream_log_entry, "el-1", entry})
      end

      # Give GenServer time to process all messages
      :sys.get_state(pid)

      buffer = StreamManager.get_buffer("el-1", server)
      assert length(buffer) == 50
      # Newest first
      assert hd(buffer).message == "log 60"
    end

    test "buffers trace spans and caps at 50", %{server: server, pid: pid} do
      StreamManager.register_trace_stream("el-2", [], server)

      for i <- 1..60 do
        span = %{
          trace_id: "trace-#{i}",
          span_id: "span-#{i}",
          name: "span #{i}",
          kind: :server,
          duration_ns: i * 1_000_000,
          status: :ok,
          status_message: nil,
          attributes: %{},
          resource: %{}
        }

        send(pid, {:stream_trace_span, "el-2", span})
      end

      :sys.get_state(pid)

      buffer = StreamManager.get_buffer("el-2", server)
      assert length(buffer) == 50
      assert hd(buffer).name == "span 60"
    end
  end

  describe "re-registration" do
    test "re-registering clears old subscription and buffer", %{server: server, pid: pid} do
      StreamManager.register_log_stream("el-1", [], server)

      entry = %{
        timestamp: System.system_time(:millisecond),
        level: :info,
        message: "old entry",
        metadata: %{}
      }

      send(pid, {:stream_log_entry, "el-1", entry})
      :sys.get_state(pid)

      assert length(StreamManager.get_buffer("el-1", server)) == 1

      # Re-register should clear the buffer
      StreamManager.register_log_stream("el-1", [level: :error], server)
      assert [] = StreamManager.get_buffer("el-1", server)
    end
  end

  describe "PubSub broadcasting" do
    test "broadcasts log entries via PubSub", %{server: server, pid: pid} do
      Phoenix.PubSub.subscribe(TimelessUI.PubSub, StreamManager.topic())
      StreamManager.register_log_stream("el-1", [], server)

      entry = %{
        timestamp: System.system_time(:millisecond),
        level: :error,
        message: "test error",
        metadata: %{}
      }

      send(pid, {:stream_log_entry, "el-1", entry})

      assert_receive {:stream_entry, "el-1", %{level: :error, message: "test error"}}, 1000
    end

    test "broadcasts trace spans via PubSub", %{server: server, pid: pid} do
      Phoenix.PubSub.subscribe(TimelessUI.PubSub, StreamManager.topic())
      StreamManager.register_trace_stream("el-2", [], server)

      span = %{
        trace_id: "t1",
        span_id: "s1",
        name: "GET /api",
        kind: :server,
        duration_ns: 15_000_000,
        status: :ok,
        status_message: nil,
        attributes: %{"service.name" => "api"},
        resource: %{}
      }

      send(pid, {:stream_trace_span, "el-2", span})

      assert_receive {:stream_span, "el-2", %{name: "GET /api", service: "api"}}, 1000
    end
  end
end
