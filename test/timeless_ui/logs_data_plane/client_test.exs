defmodule TimelessUI.LogsDataPlane.ClientTest do
  use ExUnit.Case, async: true

  alias TimelessUI.LogsDataPlane.Client

  test "decodes a complete historical response without a legacy storage dependency" do
    body =
      Jason.encode!(%{
        "_time" => "2026-08-02T12:00:00.123456Z",
        "_msg" => "ready",
        "level" => "info",
        "host" => "edge-1",
        "request_id" => "r-1"
      })

    endpoint = serve_once(body <> "\n")

    assert {:ok,
            %{
              entries: [
                %{
                  timestamp: 1_785_672_000_123_456,
                  level: :info,
                  message: "ready",
                  metadata: %{"host" => "edge-1", "request_id" => "r-1"}
                }
              ],
              has_more: false,
              limit: 10,
              offset: 0,
              total: 1
            }} = Client.query([host: "edge-1", limit: 10], base_url: endpoint)
  end

  test "field discovery is exact, bounded, and preserves stable wire order" do
    endpoint = serve_once(Jason.encode!(%{"values" => ["edge-1", "edge-2"]}))

    assert {:ok, [%{"value" => "edge-1"}, %{"value" => "edge-2"}]} =
             Client.field_values("host", [level: :error, limit: 2], base_url: endpoint)
  end

  test "unsupported query and field shapes fail before transport" do
    assert {:error, {:unsupported_capability, :logs_query_filters, [:regex]}} =
             Client.query([regex: ".*"], base_url: "http://127.0.0.1:1")

    assert {:error, {:unsupported_capability, :log_field_values, "arbitrary"}} =
             Client.field_values("arbitrary", [], base_url: "http://127.0.0.1:1")
  end

  test "process-backed calls replace caller credentials with a short-lived token" do
    token = "header.payload.signature"
    endpoint = serve_once("{}", self())
    name = {:global, {:logs_client_process, System.unique_integer([:positive])}}

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
