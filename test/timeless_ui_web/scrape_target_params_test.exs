defmodule TimelessUIWeb.ScrapeTargetParamsTest do
  @moduledoc """
  Covers the JSON fields on the scrape target form.

  Both failures these guard against were silent: invalid JSON was discarded
  without a word, and a blank field could not clear a value. Together they
  produced a target that reported healthy while storing series with none of the
  labels that make them findable.
  """
  use ExUnit.Case, async: true

  alias TimelessUIWeb.ScrapeTargetLive

  defp base(extra \\ %{}) do
    Map.merge(
      %{
        "job_name" => "node",
        "address" => "localhost:9100",
        "scheme" => "http",
        "metrics_path" => "/metrics",
        "scrape_interval" => "30",
        "scrape_timeout" => "10"
      },
      extra
    )
  end

  describe "labels as key/value rows" do
    test "rows become a label map" do
      params = base(%{"labels" => %{"0" => %{"key" => "host", "value" => "vps"}}})
      assert {:ok, out} = ScrapeTargetLive.build_api_params(params)
      assert out["labels"] == %{"host" => "vps"}
    end

    test "multiple rows keep their order-independent meaning" do
      params =
        base(%{
          "labels" => %{
            "1" => %{"key" => "env", "value" => "prod"},
            "0" => %{"key" => "host", "value" => "vps"}
          }
        })

      assert {:ok, out} = ScrapeTargetLive.build_api_params(params)
      assert out["labels"] == %{"host" => "vps", "env" => "prod"}
    end

    test "surrounding whitespace is trimmed" do
      params = base(%{"labels" => %{"0" => %{"key" => "  host ", "value" => " vps  "}}})
      assert {:ok, out} = ScrapeTargetLive.build_api_params(params)
      assert out["labels"] == %{"host" => "vps"}
    end

    test "an unfilled row is ignored rather than rejected" do
      # The form always shows a trailing blank row; it must not be an error.
      params =
        base(%{
          "labels" => %{
            "0" => %{"key" => "host", "value" => "vps"},
            "1" => %{"key" => "", "value" => ""}
          }
        })

      assert {:ok, out} = ScrapeTargetLive.build_api_params(params)
      assert out["labels"] == %{"host" => "vps"}
    end

    test "clearing every row clears the labels" do
      params = base(%{"labels" => %{"0" => %{"key" => "", "value" => ""}}})
      assert {:ok, out} = ScrapeTargetLive.build_api_params(params)
      assert out["labels"] == %{}
    end

    test "no rows at all still clears rather than leaving stale labels" do
      assert {:ok, out} = ScrapeTargetLive.build_api_params(base())
      assert out["labels"] == %{}
    end
  end

  describe "scrape timeout" do
    test "must be shorter than the interval" do
      params = base(%{"scrape_interval" => "30", "scrape_timeout" => "30"})

      assert {:error, "scrape_timeout", message} = ScrapeTargetLive.build_api_params(params)
      assert message =~ "less than the scrape interval"
    end

    test "a timeout beyond the interval is rejected" do
      params = base(%{"scrape_interval" => "10", "scrape_timeout" => "60"})
      assert {:error, "scrape_timeout", _} = ScrapeTargetLive.build_api_params(params)
    end

    test "a shorter timeout is accepted" do
      params = base(%{"scrape_interval" => "30", "scrape_timeout" => "10"})
      assert {:ok, _} = ScrapeTargetLive.build_api_params(params)
    end
  end

end
