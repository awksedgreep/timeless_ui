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
