defmodule TimelessUI.MetricsDataPlane.PromQLTest do
  use ExUnit.Case, async: true

  alias TimelessCanvas.Canvas.Element
  alias TimelessUI.MetricsDataPlane.PromQL

  describe "selector/2" do
    test "one value is equality, several are a regular expression" do
      matchers = [
        {"host", :eq, ["ohm"]},
        {"kind", :neq, ["slice", "manager"]},
        {"comm", :eq, ["postgres", "pgbouncer"]},
        {"user", :neq, ["root"]}
      ]

      assert PromQL.selector("unit_memory_bytes", matchers) ==
               ~s(unit_memory_bytes{host="ohm",kind!~"slice|manager",comm=~"postgres|pgbouncer",user!="root"})
    end

    test "a value is asked for as it is named" do
      for {value, quoted} <- [
            {"MyApp.Repo<0.512.0>", "MyApp.Repo<0.512.0>"},
            {"user@1000.service", "user@1000.service"},
            {"fn in MyApp.Report.build/2", "fn in MyApp.Report.build/2"},
            {~S(a"b), ~S(a\"b)},
            {~S(a\b), ~S(a\\b)},
            {"a\nb", ~S(a\nb)}
          ] do
        assert PromQL.selector("m", [{"proc", :eq, [value]}]) == ~s(m{proc="#{quoted}"})
      end
    end

    test "a value that is one of several is escaped as a regular expression" do
      # A dot, a bracket, and a pipe are letters here, not syntax.
      assert PromQL.selector("m", [{"proc", :eq, ["a.b[1]", "c|d"]}]) ==
               ~s(m{proc=~"a\\\\.b\\\\[1\\\\]|c\\\\|d"})
    end

    test "no matchers is every series of the metric" do
      assert PromQL.selector("m", []) == "m{}"
    end
  end

  describe "top_query/3" do
    @opts [group_by: ["comm"], limit: 10, order: :desc, aggregate: :sum]

    test "ranks groups" do
      assert PromQL.top_query("proc_cpu_pct", [{"host", :eq, ["ohm"]}], @opts) ==
               ~s|topk(10, sum by (comm) (proc_cpu_pct{host="ohm"}))|
    end

    test "ranks the series themselves with nothing to group by" do
      assert PromQL.top_query("m", [], Keyword.put(@opts, :group_by, [])) == "topk(10, m{})"
    end

    test "ascending is the bottom" do
      assert PromQL.top_query("m", [], Keyword.put(@opts, :order, :asc)) ==
               "bottomk(10, sum by (comm) (m{}))"
    end

    test "groups by several keys, and combines as asked" do
      opts = [group_by: ["comm", "user"], limit: 5, order: :desc, aggregate: :max]
      assert PromQL.top_query("m", [], opts) == "topk(5, max by (comm,user) (m{}))"
    end

    test "an aggregate that is not one of the four is a sum" do
      assert PromQL.top_query("m", [], Keyword.put(@opts, :aggregate, :median)) =~ "sum by"
    end
  end

  describe "range_query/3" do
    test "combines, or does not" do
      assert PromQL.range_query("m", [{"comm", :eq, ["chromium"]}], aggregate: :sum) ==
               ~s|sum(m{comm="chromium"})|

      assert PromQL.range_query("m", [{"comm", :eq, ["chromium"]}], []) == ~s(m{comm="chromium"})
    end
  end

  describe "rows/2" do
    @answer %{
      "status" => "success",
      "data" => %{
        "resultType" => "vector",
        "result" => [
          %{"metric" => %{"comm" => "a", "__name__" => "m"}, "value" => [1.0e9, "1.5"]},
          %{"metric" => %{"comm" => "b"}, "value" => [1.0e9, "3"]},
          %{"metric" => %{"comm" => "nan"}, "value" => [1.0e9, "NaN"]},
          %{"metric" => %{"comm" => "inf"}, "value" => [1.0e9, "+Inf"]},
          %{"metric" => "not a map", "value" => [1.0e9, "1"]},
          %{"metric" => %{"comm" => "c"}}
        ]
      }
    }

    test "are the canvas's rows, in order, with what is not a number left out" do
      assert PromQL.rows(@answer, :desc) ==
               {:ok,
                [
                  %{labels: %{"comm" => "b"}, value: 3.0},
                  %{labels: %{"comm" => "a"}, value: 1.5}
                ]}

      assert {:ok, [%{value: 1.5}, %{value: 3.0}]} = PromQL.rows(@answer, :asc)
    end

    test "an answer that is not one is an error, and does not raise" do
      for bad <- [%{}, %{"status" => "error"}, %{"status" => "success", "data" => %{}}, nil, "x"] do
        assert {:error, {:invalid_promql_response, _}} = PromQL.rows(bad, :desc)
      end
    end
  end

  describe "series/1" do
    test "are the canvas's points, in milliseconds, oldest first" do
      answer = %{
        "status" => "success",
        "data" => %{
          "result" => [
            %{"metric" => %{}, "values" => [[1_700_000_000, "1"], [1_700_000_030.5, "2.5"]]},
            %{"metric" => %{"a" => "b"}, "values" => [[1_700_000_000, "NaN"], ["x", "1"]]}
          ]
        }
      }

      assert PromQL.series(answer) ==
               {:ok,
                [
                  %{labels: %{}, points: [{1_700_000_000_000, 1.0}, {1_700_000_030_500, 2.5}]},
                  %{labels: %{"a" => "b"}, points: []}
                ]}
    end

    test "an answer that is not one is an error" do
      assert {:error, {:invalid_promql_response, _}} = PromQL.series(%{"status" => "error"})
    end
  end

  test "matchers/1 are the element's" do
    element =
      Element.new(%{
        type: :top_n,
        meta: %{"host" => "ohm", "metric_name" => "m", "label_filter" => "kind!=slice"}
      })

    assert PromQL.matchers(element) == [{"host", :eq, ["ohm"]}, {"kind", :neq, ["slice"]}]
  end
end
