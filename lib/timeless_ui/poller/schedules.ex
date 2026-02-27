defmodule TimelessUI.Poller.Schedules do
  import Ecto.Query

  alias TimelessUI.Repo
  alias TimelessUI.Poller.Schedule

  def list_schedules do
    Repo.all(from s in Schedule, order_by: [asc: s.name])
  end

  def list_enabled_schedules do
    Repo.all(from s in Schedule, where: s.enabled == true, order_by: [asc: s.name])
  end

  def get_schedule!(id), do: Repo.get!(Schedule, id)

  def get_schedule(id) do
    case Repo.get(Schedule, id) do
      nil -> {:error, :not_found}
      schedule -> {:ok, schedule}
    end
  end

  def create_schedule(attrs \\ %{}) do
    %Schedule{}
    |> Schedule.changeset(attrs)
    |> Repo.insert()
  end

  def update_schedule(%Schedule{} = schedule, attrs) do
    schedule
    |> Schedule.changeset(attrs)
    |> Repo.update()
  end

  def delete_schedule(%Schedule{} = schedule) do
    Repo.delete(schedule)
  end

  def enable_schedule(%Schedule{} = schedule) do
    update_schedule(schedule, %{enabled: true})
  end

  def disable_schedule(%Schedule{} = schedule) do
    update_schedule(schedule, %{enabled: false})
  end

  def change_schedule(%Schedule{} = schedule, attrs \\ %{}) do
    Schedule.changeset(schedule, attrs)
  end

  def validate_cron(cron_str) do
    case Crontab.CronExpression.Parser.parse(cron_str) do
      {:ok, _expr} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
