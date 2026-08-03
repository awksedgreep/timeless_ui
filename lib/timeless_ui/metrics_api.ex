defmodule TimelessUI.MetricsAPI do
  @moduledoc """
  Scrape target control for the embedded rollback data plane.

  Phoenix owns target configuration. In Rust mode this module persists that
  configuration in the Phoenix control database and publishes a versioned
  target set to the Rust metrics owner. Embedded rollback retains the original
  TimelessMetrics scraper path.
  """

  @scraper :timeless_metrics_scraper
  @unsupported {:error, {:unsupported_capability, :embedded_prometheus_scraper}}

  def list_targets do
    if rust_mode?(),
      do: rust_list_targets(),
      else: embedded(fn -> apply(TimelessMetrics.Scraper, :list_targets, [@scraper]) end)
  end

  def get_target(id) do
    if rust_mode?() do
      case Enum.find(elem_or_empty(list_targets()), &(&1.id == id)) do
        nil -> {:error, :not_found}
        target -> {:ok, target}
      end
    else
      embedded(fn -> apply(TimelessMetrics.Scraper, :get_target, [@scraper, id]) end)
    end
  end

  def create_target(params) when is_map(params) do
    if rust_mode?() do
      with {:ok, {target, _version}} <- TimelessUI.PrometheusTargets.create(params),
           :ok <- sync_rust_targets() do
        {:ok, target.id}
      end
    else
      embedded(fn -> apply(TimelessMetrics.Scraper, :add_target, [@scraper, params]) end)
    end
  end

  def update_target(id, params) when is_map(params) do
    if rust_mode?() do
      with {:ok, {_target, _version}} <- TimelessUI.PrometheusTargets.update(id, params),
           :ok <- sync_rust_targets() do
        :ok
      end
    else
      embedded(fn -> apply(TimelessMetrics.Scraper, :update_target, [@scraper, id, params]) end)
    end
  end

  def delete_target(id) do
    if rust_mode?() do
      with {:ok, :ok} <- TimelessUI.PrometheusTargets.delete(id),
           :ok <- sync_rust_targets() do
        :ok
      end
    else
      embedded(fn -> apply(TimelessMetrics.Scraper, :delete_target, [@scraper, id]) end)
    end
  end

  def sync_rust_targets do
    if rust_mode?(),
      do:
        TimelessUI.MetricsDataPlane.Client.replace_scrape_targets(
          TimelessUI.PrometheusTargets.payload()
        ),
      else: :ok
  end

  defp rust_list_targets do
    with {:ok, %{"targets" => targets}} <- TimelessUI.MetricsDataPlane.Client.scrape_targets() do
      {:ok, Enum.map(targets, &rust_target_to_ui/1)}
    end
  end

  defp rust_target_to_ui(%{"target" => target} = report) do
    %{
      id: target["id"],
      job_name: target["job_name"],
      scheme: target["scheme"],
      address: target["address"],
      metrics_path: target["metrics_path"],
      scrape_interval: target["scrape_interval_secs"],
      scrape_timeout: target["scrape_timeout_secs"],
      labels: target["labels"] || %{},
      honor_labels: false,
      honor_timestamps: true,
      metric_relabel_configs: nil,
      enabled: target["enabled"],
      health: report["health"] || "unknown",
      last_scrape: report["last_scrape_unix"],
      last_duration_ms: report["last_duration_ms"],
      last_error: report["last_error"],
      samples_scraped: report["samples_scraped"] || 0
    }
  end

  defp rust_target_to_ui(target), do: rust_target_to_ui(%{"target" => target})

  defp rust_mode?,
    do: Application.get_env(:timeless_ui, :metrics_scraper_mode, :embedded) == :rust

  defp elem_or_empty({:ok, value}), do: value
  defp elem_or_empty(_), do: []

  defp embedded(operation) do
    if Application.get_env(:timeless_ui, :metrics_scraper_mode, :embedded) == :embedded,
      do: operation.(),
      else: @unsupported
  end
end
