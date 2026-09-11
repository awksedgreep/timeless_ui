defmodule TimelessUI.TelemetryDataPlane.TailTest do
  use ExUnit.Case, async: true

  alias TimelessUI.TelemetryDataPlane.Tail

  test "bounded line splitting keeps only an incomplete tail" do
    assert {:ok, ["one", "two"], "thr"} = Tail.split_lines("", "one\ntwo\nthr", 8)
    assert {:error, :line_too_large} = Tail.split_lines("1234", "56789", 8)
  end

  test "the supervised request exits when its subscriber exits" do
    subscriber = spawn(fn -> receive do: (:stop -> :ok) end)
    test_pid = self()

    assert {:ok, tail} =
             Tail.start(subscriber, fn ->
               send(test_pid, :request_started)

               receive do
                 :never -> :ok
               end
             end)

    assert_receive :request_started
    tail_ref = Process.monitor(tail)
    send(subscriber, :stop)
    assert_receive {:DOWN, ^tail_ref, :process, ^tail, :normal}
  end
end
