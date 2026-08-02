defmodule TimelessUI.MetricsDataPlane.ClientTest do
  use ExUnit.Case, async: true

  alias TimelessUI.MetricsDataPlane.Client

  test "decodes a complete Victoria export into millisecond Canvas points" do
    body =
      Jason.encode!(%{
        "metric" => %{"__name__" => "cpu", "host" => "edge"},
        "timestamps" => [1_000, 2_000],
        "values" => [1, 2.5]
      })

    endpoint = serve_once(body)

    assert {:ok,
            [
              %{
                metric: "cpu",
                labels: %{"host" => "edge"},
                points: [{1_000, 1.0}, {2_000, 2.5}]
              }
            ]} = Client.export("cpu", %{"host" => "edge"}, 1, 2, base_url: endpoint)
  end

  test "rejects a truncated JSON body as one failed operation" do
    endpoint = serve_once(~s({"metric":))

    assert {:error, {:invalid_response, _reason}} =
             Client.export("cpu", %{}, 1, 2, base_url: endpoint)
  end

  test "rejects a connection closed before the declared response is complete" do
    endpoint = serve_once(~s({"metric":), 1_024)

    assert {:error, {:transport, _reason}} =
             Client.export("cpu", %{}, 1, 2, base_url: endpoint)
  end

  test "rejects all rows when a later NDJSON row is invalid" do
    first =
      Jason.encode!(%{
        "metric" => %{"__name__" => "cpu", "host" => "edge"},
        "timestamps" => [1_000],
        "values" => [1.0]
      })

    endpoint = serve_once(first <> "\n" <> ~s({"metric":))

    assert {:error, {:invalid_response, _reason}} =
             Client.export("cpu", %{}, 1, 2, base_url: endpoint)
  end

  test "rejects a non-loopback endpoint before opening a connection" do
    assert {:error, {:metrics_data_plane_must_use_loopback, "http://192.0.2.1:19439"}} =
             Client.export("cpu", %{}, 1, 2, base_url: "http://192.0.2.1:19439")
  end

  defp serve_once(body, declared_length \\ nil) do
    declared_length = declared_length || byte_size(body)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(listener)

    start_supervised!(
      {Task,
       fn ->
         {:ok, socket} = :gen_tcp.accept(listener)
         {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)

         response = [
           "HTTP/1.1 200 OK\r\n",
           "content-type: application/x-ndjson\r\n",
           "content-length: #{declared_length}\r\n",
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
