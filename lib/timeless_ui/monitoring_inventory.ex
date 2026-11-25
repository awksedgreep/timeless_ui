defmodule TimelessUI.MonitoringInventory do
  @moduledoc """
  Reconciles the dedicated monitoring instance from ddinfra's target manifest.

  The manifest contains target addresses and an environment variable name for
  RouterOS credentials, never credential values. Reapplying an identical
  manifest does not bump the Rust scraper target version.
  """

  alias TimelessUI.{MetricsAPI, PrometheusTarget, PrometheusTargets, Repo}
  alias TimelessUI.Poller.{Host, Request, Schedule}

  @sections ~w(scrape_targets poller_hosts poller_requests poller_schedules)

  def apply_file!(path) when is_binary(path) do
    path |> File.read!() |> Jason.decode!() |> apply!()
  end

  def apply!(manifest, opts \\ []) when is_map(manifest) do
    validate_manifest!(manifest)

    {:ok, result} =
      Repo.transaction(fn ->
        %{
          scrape_targets: Enum.count(manifest["scrape_targets"], &upsert_scrape_target!/1),
          poller_hosts: Enum.count(manifest["poller_hosts"], &upsert_poller!(Host, &1)),
          poller_requests: Enum.count(manifest["poller_requests"], &upsert_poller!(Request, &1)),
          poller_schedules:
            Enum.count(manifest["poller_schedules"], &upsert_poller!(Schedule, &1))
        }
      end)

    if Keyword.get(opts, :sync, true) do
      case MetricsAPI.sync_rust_targets() do
        :ok -> :ok
        {:error, reason} -> raise "Rust scrape target sync failed: #{inspect(reason)}"
      end
    end

    result
  end

  defp validate_manifest!(manifest) do
    Enum.each(@sections, fn section ->
      unless is_list(manifest[section]) and Enum.all?(manifest[section], &is_map/1) do
        raise ArgumentError, "#{section} must be a list of objects"
      end
    end)

    Enum.each(manifest["scrape_targets"], fn target ->
      unless get_in(target, ["labels", "managed_by"]) == "ddinfra-pmon" do
        raise ArgumentError, "scrape targets need the ddinfra-pmon ownership label"
      end

      if Map.has_key?(target, "auth") do
        raise ArgumentError, "scrape target credentials must not be in the manifest"
      end
    end)

    Enum.each(manifest["poller_requests"], fn request ->
      config = Map.get(request, "config", %{})

      unless is_map(config) and
               not (Map.has_key?(config, "password") or Map.has_key?(config, "token")) do
        raise ArgumentError, "poller request credentials must not be in the manifest"
      end
    end)
  end

  defp upsert_scrape_target!(attrs) do
    existing = Repo.get_by(PrometheusTarget, job_name: attrs["job_name"])

    case existing do
      nil ->
        {:ok, _} = PrometheusTargets.create(attrs)
        true

      target ->
        if changed?(PrometheusTarget.changeset(target, attrs)) do
          {:ok, _} = PrometheusTargets.update(target.id, attrs)
          true
        else
          false
        end
    end
  end

  defp upsert_poller!(schema, attrs) do
    existing = Repo.get_by(schema, name: attrs["name"])
    changeset = schema.changeset(existing || struct(schema), attrs)

    cond do
      not changeset.valid? ->
        raise ArgumentError, "invalid #{inspect(schema)} record #{inspect(attrs["name"])}"

      existing == nil ->
        Repo.insert!(changeset)
        true

      changed?(changeset) ->
        Repo.update!(changeset)
        true

      true ->
        false
    end
  end

  defp changed?(changeset), do: changeset.changes != %{}
end
