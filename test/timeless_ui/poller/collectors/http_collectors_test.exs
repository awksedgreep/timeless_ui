defmodule TimelessUI.Poller.Collectors.HttpCollectorsTest do
  use ExUnit.Case, async: true

  alias TimelessUI.Poller.{Host, Request}
  alias TimelessUI.Poller.Collectors.{MikrotikRestCollector, PrometheusCollector}

  test "Prometheus parsing preserves samples with and without labels" do
    body = "# HELP cpu test\ncpu{host=\"edge\",core=\"0\"} 1.5\nrequests_total 42\n"
    endpoint = serve_responses([{"text/plain", body}])
    uri = URI.parse(endpoint)
    host = %Host{name: "edge", ip: uri.host}
    request = %Request{name: "metrics", type: "prometheus"}

    assert {:ok, metrics} =
             PrometheusCollector.execute(host, request, %{
               "port" => uri.port,
               "path" => "/metrics"
             })

    assert Enum.any?(metrics, &(&1.name == "cpu" and &1.val == 1.5))
    assert Enum.any?(metrics, &(&1.name == "requests_total" and &1.val == 42.0))
  end

  test "MikroTik endpoints are collected concurrently and numeric units avoid regex parsing" do
    endpoint =
      serve_responses([
        {"application/json", ~s([{"latency":"12ms"}])},
        {"application/json", ~s([{"bytes":"2kb"}])}
      ])

    uri = URI.parse(endpoint)
    host = %Host{name: "router", ip: uri.host}
    request = %Request{name: "rest", type: "mikrotik_rest"}

    parent = self()

    task =
      start_supervised!(%{
        id: :mikrotik_collector_task,
        start:
          {Task, :start_link,
           [
             fn ->
               result =
                 MikrotikRestCollector.execute(host, request, %{
                   "username" => "admin",
                   "password" => "secret",
                   "port" => uri.port,
                   "ssl" => false,
                   "endpoints" => ["/rest/resource", "/rest/interface"]
                 })

               send(parent, {:collector_result, result})
             end
           ]}
      })

    ref = Process.monitor(task)
    assert_receive {:collector_result, {:ok, metrics}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^task, :normal}, 5_000
    assert Enum.any?(metrics, &(&1.val == 0.012))
    assert Enum.any?(metrics, &(&1.val == 2048.0))
  end

  defp serve_responses(bodies) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(listener)

    start_supervised!(
      {Task,
       fn ->
         sockets =
           Enum.map(bodies, fn _response ->
             {:ok, socket} = :gen_tcp.accept(listener)
             socket
           end)

         Enum.zip(sockets, bodies)
         |> Enum.each(fn {socket, {content_type, body}} ->
           {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)

           response = [
             "HTTP/1.1 200 OK\r\n",
             "content-type: #{content_type}\r\n",
             "content-length: #{byte_size(body)}\r\n",
             "connection: close\r\n\r\n",
             body
           ]

           :ok = :gen_tcp.send(socket, response)
           :gen_tcp.close(socket)
         end)

         :gen_tcp.close(listener)
       end}
    )

    "http://127.0.0.1:#{port}"
  end
end
