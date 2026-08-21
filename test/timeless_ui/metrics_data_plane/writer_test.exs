defmodule TimelessUI.MetricsDataPlane.WriterTest do
  use ExUnit.Case, async: true

  alias TimelessUI.MetricsDataPlane.Writer

  # Epoch seconds, per TimelessUI.Poller.Collector.metric_data. Derived from
  # now so the plausibility window never ages these out.
  defp seconds(offset \\ 0), do: System.system_time(:second) + offset

  test "groups numeric poller values into one public VictoriaMetrics request" do
    metrics = [
      %{name: "cpu", host: "edge", type: :gauge, labels: %{rack: "r1"}, val: 1, ts: seconds(-1)},
      %{name: "cpu", host: "edge", type: :gauge, labels: %{rack: "r1"}, val: 2.5, ts: seconds()}
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

    # The import surface takes milliseconds; the collector contract is seconds.
    assert decoded["timestamps"] == [(seconds() - 1) * 1_000, seconds() * 1_000]
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
      ts: seconds()
    }

    numeric_metric = %{
      name: "cpu",
      host: "edge",
      type: :gauge,
      labels: %{},
      val: 3,
      val_type: :number,
      ts: seconds()
    }

    assert {:error, {:unsupported_capability, :text_metrics, 1}} =
             Writer.write_metrics([text_metric, numeric_metric],
               client: TimelessUI.MetricsDataPlaneWriterClientFixture,
               client_opts: [notify: self()]
             )

    assert_receive {:victoria_import, body}
    assert body =~ ~s("__name__":"cpu")
  end

  describe "timestamp units" do
    test "a millisecond timestamp is refused instead of ingested" do
      # This is the bug the guard exists for: milliseconds where seconds are
      # expected multiply out to roughly the year 58,600. The import succeeds,
      # the series appears in /api/v1/series, and every query returns nothing
      # -- indistinguishable from a poller that never ran.
      metric = %{
        name: "icmp_ping_success",
        host: "edge",
        type: "icmp",
        labels: %{},
        val: 1,
        ts: System.system_time(:millisecond)
      }

      assert {:error, {:implausible_timestamp, "icmp_ping_success", _ts}} =
               Writer.write_metrics([metric],
                 client: TimelessUI.MetricsDataPlaneWriterClientFixture,
                 client_opts: [notify: self()]
               )

      refute_receive {:victoria_import, _body}
    end

    test "a plausible past timestamp is accepted" do
      metric = %{
        name: "cpu",
        host: "edge",
        type: "gauge",
        labels: %{},
        val: 1,
        ts: seconds(-3600)
      }

      assert :ok =
               Writer.write_metrics([metric],
                 client: TimelessUI.MetricsDataPlaneWriterClientFixture,
                 client_opts: [notify: self()]
               )
    end
  end
end
