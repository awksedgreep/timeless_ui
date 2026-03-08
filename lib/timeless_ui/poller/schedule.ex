defmodule TimelessUI.Poller.Schedule do
  use Ecto.Schema
  import Ecto.Changeset

  schema "poller_schedules" do
    field :name, :string
    field :cron, :string
    field :host_tags, :string, default: ""
    field :request_tags, :string, default: ""
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name cron)a
  @optional_fields ~w(host_tags request_tags enabled)a

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

  def host_tags_list(%__MODULE__{host_tags: tags}) when is_binary(tags) do
    tags |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

  def host_tags_list(%__MODULE__{}), do: []

  def request_tags_list(%__MODULE__{request_tags: tags}) when is_binary(tags) do
    tags |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

  def request_tags_list(%__MODULE__{}), do: []
end
