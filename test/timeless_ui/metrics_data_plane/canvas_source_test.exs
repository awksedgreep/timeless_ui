defmodule TimelessUI.MetricsDataPlane.CanvasSourceTest do
  use ExUnit.Case, async: true

  alias TimelessCanvas.Canvas.Element
  alias TimelessUI.MetricsDataPlane.CanvasSource

  @from DateTime.from_unix!(1_728_000_000)
  @to DateTime.from_unix!(1_728_000_120)
  @points [{1_728_000_000_000, 1.5}, {1_728_000_001_000, 2.5}]

  test "configuration switches one Canvas metric range without changing its public result" do
    element = graph_element()

    assert {:ok, fallback_state} =
             CanvasSource.init(%{
               source: :fallback,
               fallback: TimelessUI.CanvasDataSourceFixture,
               fallback_config: %{metric_range: {:ok, @points}}
             })

    assert {:ok, data_plane_state} =
             CanvasSource.init(%{
               source: :data_plane,
               fallback: TimelessUI.CanvasDataSourceFixture,
               fallback_config: %{metric_range: {:ok, []}},
               client: TimelessUI.MetricsDataPlaneClientFixture,
               client_opts: [
                 notify: self(),
                 result:
                   {:ok,
                    [
                      %{
                        metric: "canvas_cpu",
                        labels: %{"env" => "test", "host" => "edge", "rack" => "r1"},
                        points: @points
                      }
                    ]}
               ]
             })

    fallback = CanvasSource.metric_range(fallback_state, element, "canvas_cpu", @from, @to)
    data_plane = CanvasSource.metric_range(data_plane_state, element, "canvas_cpu", @from, @to)

    assert data_plane == fallback

    assert_receive {:metrics_export, "canvas_cpu",
                    %{"env" => "test", "host" => "edge", "rack" => "r1"}, 1_728_000_000,
                    1_728_000_120}
  end

  test "a failed or invalid complete operation is an error, never partial Canvas data" do
    assert {:ok, state} =
             CanvasSource.init(%{
               client: TimelessUI.MetricsDataPlaneClientFixture,
               client_opts: [result: {:error, {:invalid_response, :truncated}}]
             })

    assert {:error, {:invalid_response, :truncated}} =
             CanvasSource.metric_range(state, graph_element(), "canvas_cpu", @from, @to)
  end

  test "a series is found by the labels the element names, whatever else it has" do
    # A process series carries more than an element names it by.
    series = [
      %{
        metric: "proc_cpu_pct",
        labels: %{
          "host" => "ohm",
          "proc" => "postgres[4548]",
          "pid" => "4548",
          "comm" => "postgres",
          "user" => "postgres",
          "unit" => "postgresql.service"
        },
        points: @points
      }
    ]

    element =
      Element.new(%{
        id: "pg",
        type: :graph,
        meta: %{"metric_name" => "proc_cpu_pct", "host" => "ohm", "proc" => "postgres[4548]"}
      })

    {:ok, state} = data_plane_state(result: {:ok, series})
    assert CanvasSource.metric_range(state, element, "proc_cpu_pct", @from, @to) == {:ok, @points}
  end

  test "two series that both have the element's labels are still an error, not the first" do
    series =
      for pid <- ["1", "2"] do
        %{
          metric: "m",
          labels: %{"host" => "ohm", "comm" => "postgres", "pid" => pid},
          points: @points
        }
      end

    element =
      Element.new(%{
        id: "g",
        type: :graph,
        meta: %{"metric_name" => "m", "host" => "ohm", "comm" => "postgres"}
      })

    {:ok, state} = data_plane_state(result: {:ok, series})

    assert {:error, {:ambiguous_series, "m", %{"host" => "ohm", "comm" => "postgres"}}} =
             CanvasSource.metric_range(state, element, "m", @from, @to)
  end

  test "the canvas's own options are not sent as labels" do
    element =
      Element.new(%{
        id: "g",
        type: :graph,
        meta: %{
          "metric_name" => "m",
          "host" => "ohm",
          "aggregate" => "",
          "window" => "",
          "label_filter" => "",
          "group_by" => "",
          "limit" => "",
          "order" => "",
          "icon" => "server",
          "y_max" => "100"
        }
      })

    {:ok, state} = data_plane_state(result: {:ok, []}, notify: self())
    assert {:ok, []} = CanvasSource.metric_range(state, element, "m", @from, @to)
    assert_receive {:metrics_export, "m", %{"host" => "ohm"} = labels, _, _}
    assert map_size(labels) == 1
  end

  describe "metric_range/6" do
    @promql_range %{
      "status" => "success",
      "data" => %{
        "result" => [
          %{"metric" => %{}, "values" => [[1_728_000_000, "4"], [1_728_000_060, "6"]]}
        ]
      }
    }

    test "combines the series the element matches, with the lookback it sets" do
      element =
        Element.new(%{
          id: "g",
          type: :graph,
          meta: %{
            "metric_name" => "proc_rss_bytes",
            "host" => "ohm",
            "comm" => "chromium",
            "aggregate" => "sum",
            "label_filter" => "user!=root",
            "window" => "45"
          }
        })

      {:ok, state} = data_plane_state(promql_result: {:ok, @promql_range}, notify: self())
      opts = TimelessCanvas.DataQueries.build_range_opts(element.meta)

      assert CanvasSource.metric_range(state, element, "proc_rss_bytes", @from, @to, opts) ==
               {:ok, [{1_728_000_000_000, 4.0}, {1_728_000_060_000, 6.0}]}

      assert_receive {:promql_range, query, 1_728_000_000, 1_728_000_120, step, 45}
      assert query == ~s|sum(proc_rss_bytes{comm="chromium",host="ohm",user!="root"})|
      assert step >= 1
    end

    test "without an aggregate it is one series, as metric_range/5 is" do
      element =
        Element.new(%{id: "g", type: :graph, meta: %{"metric_name" => "m", "host" => "ohm"}})

      one = %{
        "status" => "success",
        "data" => %{"result" => [%{"metric" => %{"a" => "1"}, "values" => [[1, "1"]]}]}
      }

      {:ok, state} = data_plane_state(promql_result: {:ok, one}, notify: self())

      assert {:ok, [{1000, 1.0}]} =
               CanvasSource.metric_range(state, element, "m", @from, @to, window: 30)

      assert_receive {:promql_range, ~s(m{host="ohm"}), _, _, _, 30}

      two =
        put_in(one, ["data", "result"], [
          %{"metric" => %{"a" => "1"}, "values" => []},
          %{"metric" => %{"a" => "2"}, "values" => []}
        ])

      {:ok, state} = data_plane_state(promql_result: {:ok, two})

      assert {:error, {:ambiguous_series, "m", _}} =
               CanvasSource.metric_range(state, element, "m", @from, @to, [])
    end

    test "the source's lookback is used where the element sets none" do
      element =
        Element.new(%{id: "g", type: :graph, meta: %{"metric_name" => "m", "aggregate" => "max"}})

      {:ok, state} =
        data_plane_state(
          promql_result: {:ok, @promql_range},
          notify: self(),
          lookback_seconds: 20
        )

      assert {:ok, _} =
               CanvasSource.metric_range(state, element, "m", @from, @to, aggregate: :max)

      assert_receive {:promql_range, "max(m{})", _, _, _, 20}

      {:ok, state} = data_plane_state(promql_result: {:ok, @promql_range}, notify: self())

      assert {:ok, _} =
               CanvasSource.metric_range(state, element, "m", @from, @to, aggregate: :max)

      assert_receive {:promql_range, "max(m{})", _, _, _, 30}
    end

    test "a plane that refuses is an error, never partial data" do
      element =
        Element.new(%{id: "g", type: :graph, meta: %{"metric_name" => "m", "aggregate" => "sum"}})

      {:ok, state} =
        data_plane_state(promql_result: {:error, {:unexpected_response, 422, "work limit"}})

      assert {:error, {:unexpected_response, 422, "work limit"}} =
               CanvasSource.metric_range(state, element, "m", @from, @to, aggregate: :sum)
    end
  end

  describe "top_series/5" do
    @promql_instant %{
      "status" => "success",
      "data" => %{
        "result" => [
          %{"metric" => %{"comm" => "beam.smp"}, "value" => [1_728_000_100.5, "103.2"]},
          %{"metric" => %{"comm" => "cc1plus"}, "value" => [1_728_000_100.5, "887"]}
        ]
      }
    }

    test "ranks through the PromQL route, at the time asked, with the lookback" do
      element =
        Element.new(%{
          id: "t",
          type: :top_n,
          meta: %{
            "metric_name" => "procgroup_cpu_pct",
            "host" => "ohm",
            "group_by" => "comm",
            "limit" => "2",
            "window" => "30"
          }
        })

      opts = TimelessCanvas.DataQueries.build_top_opts(element.meta)
      {:ok, state} = data_plane_state(promql_result: {:ok, @promql_instant}, notify: self())
      time = DateTime.from_unix!(1_728_000_100)

      assert CanvasSource.top_series(state, element, "procgroup_cpu_pct", time, opts) ==
               {:ok,
                [
                  %{labels: %{"comm" => "cc1plus"}, value: 887.0},
                  %{labels: %{"comm" => "beam.smp"}, value: 103.2}
                ]}

      assert_receive {:promql_instant, query, 1_728_000_100, 30}
      assert query == ~s|topk(2, sum by (comm) (procgroup_cpu_pct{host="ohm"}))|
    end

    test "ascending is the bottom, in ascending order" do
      element =
        Element.new(%{id: "t", type: :top_n, meta: %{"metric_name" => "m", "order" => "asc"}})

      opts = TimelessCanvas.DataQueries.build_top_opts(element.meta)
      {:ok, state} = data_plane_state(promql_result: {:ok, @promql_instant}, notify: self())

      assert {:ok, [%{value: 103.2}, %{value: 887.0}]} =
               CanvasSource.top_series(state, element, "m", @to, opts)

      assert_receive {:promql_instant, "bottomk(10, m{})", _, 30}
    end
  end

  describe "with source: :fallback" do
    test "the new callbacks go to a fallback that has them, and are an error where it has not" do
      element = Element.new(%{id: "t", type: :top_n, meta: %{"metric_name" => "m"}})

      {:ok, without} =
        CanvasSource.init(%{
          source: :fallback,
          fallback: TimelessUI.CanvasDataSourceFixture,
          fallback_config: %{metric_range: {:ok, []}}
        })

      assert {:error, {:unsupported_by_fallback, :top_series}} =
               CanvasSource.top_series(without, element, "m", @to, limit: 5)

      assert {:error, {:unsupported_by_fallback, :metric_range}} =
               CanvasSource.metric_range(without, element, "m", @from, @to, aggregate: :sum)

      {:ok, with_them} =
        CanvasSource.init(%{
          source: :fallback,
          fallback: TimelessUI.RankingCanvasDataSourceFixture,
          fallback_config: %{}
        })

      assert {:ok, [%{labels: %{"from" => "fallback"}, value: 1.0}]} =
               CanvasSource.top_series(with_them, element, "m", @to, limit: 5)

      assert {:ok, [{1, 1.0}]} =
               CanvasSource.metric_range(with_them, element, "m", @from, @to, aggregate: :sum)
    end
  end

  defp data_plane_state(client_opts) do
    {lookback, client_opts} = Keyword.pop(client_opts, :lookback_seconds)

    config = %{
      source: :data_plane,
      fallback: TimelessUI.CanvasDataSourceFixture,
      fallback_config: %{metric_range: {:ok, []}},
      client: TimelessUI.MetricsDataPlaneClientFixture,
      client_opts: client_opts
    }

    CanvasSource.init(
      if(lookback, do: Map.put(config, :lookback_seconds, lookback), else: config)
    )
  end

  defp graph_element do
    Element.new(%{
      id: "cpu-graph",
      type: :graph,
      meta: %{
        "metric_name" => "canvas_cpu",
        "host" => "edge",
        "env" => "test",
        "series_label_key" => "rack",
        "series_label_value" => "r1",
        "y_min" => "0",
        "icon" => "server"
      }
    })
  end
end
