defmodule TimelessUI.PrometheusTargetsTest do
  use TimelessUI.DataCase

  alias TimelessUI.{MetricsAPI, PrometheusTargets}

  test "mutations return the bumped version without a follow-up version query" do
    initial = PrometheusTargets.version()

    assert {:ok, {target, version}} =
             PrometheusTargets.create(%{job_name: "node", address: "127.0.0.1:9100"})

    assert version == initial + 1

    assert {:ok, {updated, next_version}} =
             PrometheusTargets.update(target.id, %{metrics_path: "/custom"})

    assert updated.metrics_path == "/custom"
    assert next_version == version + 1
    assert {:ok, final_version} = PrometheusTargets.delete(target.id)
    assert final_version == next_version + 1
  end

  test "Rust-mode target lookup reads the local control-plane row" do
    previous = Application.get_env(:timeless_ui, :metrics_scraper_mode)
    Application.put_env(:timeless_ui, :metrics_scraper_mode, :rust)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:timeless_ui, :metrics_scraper_mode),
        else: Application.put_env(:timeless_ui, :metrics_scraper_mode, previous)
    end)

    assert {:ok, {target, _version}} =
             PrometheusTargets.create(%{job_name: "local", address: "127.0.0.1:9100"})

    assert {:ok, found} = MetricsAPI.get_target(target.id)
    assert found.id == target.id
    assert {:error, :not_found} = MetricsAPI.get_target(target.id + 1_000_000)
  end
end
