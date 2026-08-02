defmodule TimelessUI.TracesDataPlane.ClientTest do
  use ExUnit.Case, async: true

  alias TimelessUI.TracesDataPlane.Client

  @trace_id "00112233445566778899aabbccddeeff"
  @span_id "0011223344556677"

  test "backup preserves the complete Rust maintenance report" do
    request = fn options ->
      send(self(), {:backup_request, options})
      {:ok, %{status: 200, body: ~s({"signal":"traces","bytes":44})}}
    end

    assert {:ok, %{"signal" => "traces", "bytes" => 44}} =
             Client.backup("/backup/traces.db",
               base_url: "http://127.0.0.1:19449",
               request: request
             )

    assert_received {:backup_request, options}
    assert options[:method] == :post
    assert options[:url] == "http://127.0.0.1:19449/api/v1/backup"
    assert Jason.decode!(options[:body]) == %{"destination" => "/backup/traces.db"}
  end

  test "decodes every rich-span field as one complete historical operation" do
    span = span_fixture()

    body =
      Jason.encode!(%{
        "entries" => [span],
        "total" => 1,
        "limit" => 10,
        "offset" => 0,
        "has_more" => false
      })

    endpoint = serve_once(body)

    assert {:ok, %{entries: [decoded], total: 1, has_more: false}} =
             Client.search([service: "checkout", limit: 10], base_url: endpoint)

    assert decoded.trace_id == @trace_id
    assert decoded.span_id == @span_id
    assert decoded.parent_span_id == nil
    assert decoded.kind == :server
    assert decoded.status == :error
    assert decoded.attributes == span["attributes"]
    assert decoded.events == span["events"]
    assert decoded.resource == span["resource"]
    assert decoded.instrumentation_scope == span["instrumentation_scope"]
    refute Map.has_key?(decoded, :wire)
  end

  test "rejects inconsistent duration and the entire response" do
    body =
      Jason.encode!(%{
        "entries" => [Map.put(span_fixture(), "duration_ns", 1)],
        "total" => 1,
        "limit" => 10,
        "offset" => 0,
        "has_more" => false
      })

    endpoint = serve_once(body)

    assert {:error, {:invalid_span, :inconsistent_duration}} =
             Client.search([], base_url: endpoint)
  end

  test "unsupported native filters fail before transport" do
    assert {:error, {:unsupported_capability, :traces_query_filters, [:attribute]}} =
             Client.search([attribute: "http.method=GET"], base_url: "http://127.0.0.1:1")
  end

  test "process-backed calls replace caller credentials with a short-lived token" do
    token = "header.payload.signature"
    endpoint = serve_once("{}", self())
    name = {:global, {:traces_client_process, System.unique_integer([:positive])}}

    start_supervised!(
      {TimelessUI.MetricsDataPlaneProcessFixture, name: name, endpoint: endpoint, token: token}
    )

    assert {:ok, %{}} =
             Client.health(
               process: name,
               headers: [{"authorization", "Bearer caller-must-not-win"}]
             )

    assert_receive {:request, request}
    assert String.downcase(request) =~ "authorization: bearer #{token}"
    refute request =~ "caller-must-not-win"
  end

  defp span_fixture do
    %{
      "trace_id" => @trace_id,
      "span_id" => @span_id,
      "parent_span_id" => nil,
      "name" => "POST /checkout",
      "kind" => "server",
      "start_time" => 100,
      "end_time" => 175,
      "duration_ns" => 75,
      "status" => "error",
      "status_message" => "declined",
      "attributes" => %{"http.method" => "POST", "attempt" => 2, "sampled" => true},
      "events" => [
        %{"name" => "exception", "timestamp" => 130, "attributes" => %{"type" => "Declined"}}
      ],
      "resource" => %{"service.name" => "checkout", "service.instance.id" => "edge-1"},
      "instrumentation_scope" => %{"name" => "checkout-web", "version" => "2.1.0"}
    }
  end

  defp serve_once(body, notify \\ nil) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(listener)

    start_supervised!(
      {Task,
       fn ->
         {:ok, socket} = :gen_tcp.accept(listener)
         {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
         if is_pid(notify), do: send(notify, {:request, request})

         response = [
           "HTTP/1.1 200 OK\r\n",
           "content-type: application/json\r\n",
           "content-length: #{byte_size(body)}\r\n",
           "connection: close\r\n\r\n",
           body
         ]

         :ok = :gen_tcp.send(socket, response)
         :gen_tcp.close(socket)
         :gen_tcp.close(listener)
       end}
    )

    "http://127.0.0.1:#{port}"
  end
end
