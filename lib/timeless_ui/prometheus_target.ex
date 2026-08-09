defmodule TimelessUI.PrometheusTarget do
  use Ecto.Schema
  import Ecto.Changeset

  schema "prometheus_targets" do
    field :job_name, :string
    field :scheme, :string, default: "http"
    field :address, :string
    field :metrics_path, :string, default: "/metrics"
    field :scrape_interval, :integer, default: 30
    field :scrape_timeout, :integer, default: 10
    field :labels, :map, default: %{}
    field :auth, :map
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def changeset(target, attrs) do
    target
    |> cast(attrs, [
      :job_name,
      :scheme,
      :address,
      :metrics_path,
      :scrape_interval,
      :scrape_timeout,
      :labels,
      :auth,
      :enabled
    ])
    |> validate_required([:job_name, :address])
    |> validate_inclusion(:scheme, ["http", "https"])
    |> validate_number(:scrape_interval, greater_than: 0, less_than_or_equal_to: 86_400)
    |> validate_number(:scrape_timeout, greater_than: 0, less_than_or_equal_to: 300)
    |> validate_change(:labels, &validate_labels/2)
    |> unique_constraint(:job_name)
  end

  defp validate_labels(:labels, labels) when is_map(labels) do
    if Enum.all?(Map.keys(labels), &is_binary/1), do: [], else: [labels: "must use string keys"]
  end

  defp validate_labels(:labels, _), do: [labels: "must be a map"]
end
