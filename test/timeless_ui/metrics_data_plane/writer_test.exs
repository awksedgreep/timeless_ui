defmodule TimelessUI.MetricsDataPlane.WriterTest do
  use ExUnit.Case, async: true

  alias TimelessUI.MetricsDataPlane.Writer

  test "groups numeric poller values into one public VictoriaMetrics request" do
    metrics = [
      %{name: "cpu", host: "edge", type: :gauge, labels: %{rack: "r1"}, val: 1, ts: 10},
      %{name: "cpu", host: "edge", type: :gauge, labels: %{rack: "r1"}, val: 2.5, ts: 11}
    ]

    assert :ok =
             Writer.write_metrics(metrics,
               client: TimelessUI.MetricsDataPlaneWriterClientFixture,
               client_opts: [notify: self()]
             )

    assert_receive {:victoria_import, body}
    assert [line] = String.split(body, "\n", trim: true)
    assert {:ok, decoded} = Jason.decode(line)

    assert decoded["metric"] == %{
             "__name__" => "cpu",
             "host" => "edge",
             "rack" => "r1",
             "type" => "gauge"
           }

    assert decoded["timestamps"] == [10_000, 11_000]
    assert decoded["values"] == [1.0, 2.5]
  end

  test "mixed results persist supported numerics and report text metrics explicitly" do
    text_metric = %{
      name: "version",
      host: "edge",
      type: :info,
      labels: %{},
      val: "v1",
      val_type: :text,
      ts: 10
    }

    numeric_metric = %{
      name: "cpu",
      host: "edge",
      type: :gauge,
      labels: %{},
      val: 3,
      val_type: :number,
      ts: 10
    }

    assert {:error, {:unsupported_capability, :text_metrics, 1}} =
             Writer.write_metrics([text_metric, numeric_metric],
               client: TimelessUI.MetricsDataPlaneWriterClientFixture,
               client_opts: [notify: self()]
             )

    assert_receive {:victoria_import, body}
    assert body =~ ~s("__name__":"cpu")
  end
end
