defmodule TimelessUI.Poller.Schedule do
  use Ecto.Schema
  import Ecto.Changeset

  schema "poller_schedules" do
    field :name, :string
    field :cron, :string
    field :host_groups, :map, default: %{}
    field :request_groups, :map, default: %{}
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name cron)a
  @optional_fields ~w(host_groups request_groups enabled)a

  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_cron()
    |> unique_constraint(:name)
  end

  defp validate_cron(changeset) do
    case get_change(changeset, :cron) do
      nil ->
        changeset

      cron_str ->
        case Crontab.CronExpression.Parser.parse(cron_str) do
          {:ok, _} -> changeset
          {:error, _} -> add_error(changeset, :cron, "is not a valid cron expression")
        end
    end
  end

  def host_groups(%__MODULE__{host_groups: groups}), do: groups || %{}
  def request_groups(%__MODULE__{request_groups: groups}), do: groups || %{}
end
