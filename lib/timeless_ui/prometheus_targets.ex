defmodule TimelessUI.PrometheusTargets do
  import Ecto.Query

  alias TimelessUI.{PrometheusTarget, Repo}

  def list, do: Repo.all(from target in PrometheusTarget, order_by: [asc: target.id])
  def get(id), do: Repo.get(PrometheusTarget, id)

  def create(attrs) do
    Repo.transaction(fn ->
      case Repo.insert(PrometheusTarget.changeset(%PrometheusTarget{}, attrs)) do
        {:ok, target} -> {target, bump_version!()}
        {:error, changeset} -> Repo.rollback({:changeset, changeset})
      end
    end)
  end

  def update(id, attrs) do
    Repo.transaction(fn ->
      target = Repo.get(PrometheusTarget, id) || Repo.rollback(:not_found)

      case Repo.update(PrometheusTarget.changeset(target, attrs)) do
        {:ok, target} -> {target, bump_version!()}
        {:error, changeset} -> Repo.rollback({:changeset, changeset})
      end
    end)
  end

  def delete(id) do
    Repo.transaction(fn ->
      case Repo.get(PrometheusTarget, id) do
        nil ->
          Repo.rollback(:not_found)

        target ->
          {:ok, _deleted} = Repo.delete(target)
          bump_version!()
          :ok
      end
    end)
  end

  def version do
    Repo.get!(TimelessUI.PrometheusTargetState, 1).version
  end

  def payload do
    %{
      version: version(),
      targets: Enum.map(list(), &to_rust_target/1)
    }
  end

  def to_rust_target(%PrometheusTarget{} = target) do
    %{
      id: target.id,
      job_name: target.job_name,
      scheme: target.scheme,
      address: target.address,
      metrics_path: target.metrics_path,
      scrape_interval_secs: target.scrape_interval,
      scrape_timeout_secs: target.scrape_timeout,
      labels: target.labels || %{},
      auth: target.auth,
      enabled: target.enabled
    }
  end

  def from_rust(target, report) do
    target
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.merge(%{
      "scrape_interval" => target["scrape_interval_secs"],
      "scrape_timeout" => target["scrape_timeout_secs"],
      "health" => report["health"] || "unknown",
      "last_scrape" => report["last_scrape_unix"],
      "last_duration_ms" => report["last_duration_ms"],
      "last_error" => report["last_error"],
      "samples_scraped" => report["samples_scraped"] || 0
    })
  end

  defp bump_version! do
    {1, _} = Repo.update_all(TimelessUI.PrometheusTargetState, inc: [version: 1])
    version()
  end
end

defmodule TimelessUI.PrometheusTargetState do
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "prometheus_target_state" do
    field :version, :integer
    timestamps(type: :utc_datetime)
  end
end
