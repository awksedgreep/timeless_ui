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

  describe "valid input" do
    test "labels are parsed into a map" do
      assert {:ok, params} = ScrapeTargetLive.build_api_params(base(%{"labels" => ~s({"host": "vps"})}))
      assert params["labels"] == %{"host" => "vps"}
    end

    test "surrounding whitespace is tolerated" do
      assert {:ok, params} =
               ScrapeTargetLive.build_api_params(base(%{"labels" => ~s(  {"host": "vps"}\n)}))

      assert params["labels"] == %{"host" => "vps"}
    end
  end

  describe "invalid input" do
    test "is reported rather than discarded" do
      # The whole point: an operator who types host=vps must be told, not
      # silently given a target with no labels.
      assert {:error, "labels", message} =
               ScrapeTargetLive.build_api_params(base(%{"labels" => "host=vps"}))

      assert is_binary(message)
    end

    test "names the field that failed" do
      assert {:error, "metric_relabel_configs", _} =
               ScrapeTargetLive.build_api_params(base(%{"metric_relabel_configs" => "[oops"}))
    end

    test "a valid field does not mask an invalid one" do
      params = base(%{"labels" => ~s({"a": "b"}), "metric_relabel_configs" => "{"})
      assert {:error, "metric_relabel_configs", _} = ScrapeTargetLive.build_api_params(params)
    end
  end

  describe "clearing" do
    test "a blank field clears labels rather than leaving them" do
      assert {:ok, params} = ScrapeTargetLive.build_api_params(base(%{"labels" => ""}))
      assert params["labels"] == %{}
    end

    test "whitespace only also clears" do
      assert {:ok, params} = ScrapeTargetLive.build_api_params(base(%{"labels" => "   "}))
      assert params["labels"] == %{}
    end

    test "an absent field is left untouched" do
      # Absent and blank are different: only one of them is an instruction.
      assert {:ok, params} = ScrapeTargetLive.build_api_params(base())
      refute Map.has_key?(params, "labels")
    end
  end
end
