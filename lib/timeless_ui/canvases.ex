defmodule TimelessUI.Canvases do
  import Ecto.Query
  alias TimelessUI.Repo
  alias TimelessUI.Canvases.CanvasRecord

  def get_canvas(name) do
    case Repo.get_by(CanvasRecord, name: name) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  def save_canvas(name, data) do
    case Repo.get_by(CanvasRecord, name: name) do
      nil ->
        %CanvasRecord{}
        |> CanvasRecord.changeset(%{name: name, data: data})
        |> Repo.insert()

      existing ->
        existing
        |> CanvasRecord.changeset(%{data: data})
        |> Repo.update()
    end
  end

  def list_canvases do
    CanvasRecord
    |> select([c], c.name)
    |> order_by([c], asc: c.name)
    |> Repo.all()
  end

  def delete_canvas(name) do
    case Repo.get_by(CanvasRecord, name: name) do
      nil -> {:error, :not_found}
      record -> Repo.delete(record)
    end
  end
end
