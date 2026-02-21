defmodule TimelessUI.Canvases do
  import Ecto.Query
  alias TimelessUI.Repo
  alias TimelessUI.Canvases.CanvasRecord

  @doc """
  Get a canvas by ID. Auth is checked at the LiveView layer.
  """
  def get_canvas(id) do
    case Repo.get(CanvasRecord, id) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @doc """
  Save (upsert) a canvas for a user. If a canvas with the same name
  exists for this user, update its data. Otherwise, create a new one.
  """
  def save_canvas(user_id, name, data) do
    case Repo.get_by(CanvasRecord, user_id: user_id, name: name) do
      nil ->
        %CanvasRecord{}
        |> CanvasRecord.changeset(%{user_id: user_id, name: name, data: data})
        |> Repo.insert()

      existing ->
        existing
        |> CanvasRecord.changeset(%{data: data})
        |> Repo.update()
    end
  end

  @doc """
  Create a new canvas with empty data for a user.
  """
  def create_canvas(user_id, name) do
    %CanvasRecord{}
    |> CanvasRecord.changeset(%{user_id: user_id, name: name, data: %{}})
    |> Repo.insert()
  end

  @doc """
  Get an existing canvas by user_id + name, or create one with empty data.
  """
  def get_or_create_canvas(user_id, name) do
    case Repo.get_by(CanvasRecord, user_id: user_id, name: name) do
      nil -> create_canvas(user_id, name)
      record -> {:ok, record}
    end
  end

  @doc """
  List all canvases owned by a user.
  """
  def list_canvases_for_user(user_id) do
    CanvasRecord
    |> where([c], c.user_id == ^user_id)
    |> order_by([c], asc: c.name)
    |> Repo.all()
  end

  @doc """
  Delete a canvas only if owned by the given user.
  """
  def delete_canvas(id, user_id) do
    case Repo.get_by(CanvasRecord, id: id, user_id: user_id) do
      nil -> {:error, :not_found}
      record -> Repo.delete(record)
    end
  end

  @doc """
  Update canvas data by ID (for autosave).
  """
  def update_canvas_data(canvas_id, data) do
    case Repo.get(CanvasRecord, canvas_id) do
      nil ->
        {:error, :not_found}

      record ->
        record
        |> CanvasRecord.changeset(%{data: data})
        |> Repo.update()
    end
  end
end
