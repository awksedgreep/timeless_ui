defmodule TimelessUI.Canvases do
  import Ecto.Query
  alias TimelessUI.Repo
  alias TimelessUI.Canvases.{CanvasRecord, CanvasAccess}

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
  Create a child canvas under the given parent. Inherits the parent's user_id.
  """
  def create_child_canvas(parent_id, name) do
    case Repo.get(CanvasRecord, parent_id) do
      nil ->
        {:error, :parent_not_found}

      parent ->
        %CanvasRecord{}
        |> CanvasRecord.changeset(%{
          user_id: parent.user_id,
          name: name,
          data: %{},
          parent_id: parent.id
        })
        |> Repo.insert()
    end
  end

  @doc """
  Walk parent_id chain from a canvas up to root.
  Returns `[{id, name}, ...]` ordered root-first.
  """
  def breadcrumb_chain(canvas_id) do
    case Repo.get(CanvasRecord, canvas_id) do
      nil -> []
      record -> build_chain(record, [{record.id, record.name}])
    end
  end

  defp build_chain(%{parent_id: nil}, acc), do: acc

  defp build_chain(%{parent_id: parent_id}, acc) do
    case Repo.get(CanvasRecord, parent_id) do
      nil -> acc
      parent -> build_chain(parent, [{parent.id, parent.name} | acc])
    end
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

  # --- Access management ---

  @doc """
  List all canvases a user can access (owned + shared).
  """
  def list_accessible_canvases(user) do
    owned =
      CanvasRecord
      |> where([c], c.user_id == ^user.id)

    shared_ids =
      CanvasAccess
      |> where([a], a.user_id == ^user.id)
      |> select([a], a.canvas_id)

    shared =
      CanvasRecord
      |> where([c], c.id in subquery(shared_ids))

    union_query = union(owned, ^shared)

    from(c in subquery(union_query), order_by: [asc: c.name])
    |> Repo.all()
  end

  @doc """
  Grant access to a canvas for a user. Upserts on conflict.
  """
  def grant_access(canvas_id, user_id, role) do
    %CanvasAccess{}
    |> CanvasAccess.changeset(%{canvas_id: canvas_id, user_id: user_id, role: role})
    |> Repo.insert(
      on_conflict: [set: [role: role]],
      conflict_target: [:canvas_id, :user_id]
    )
  end

  @doc """
  Revoke access from a user for a canvas.
  """
  def revoke_access(canvas_id, user_id) do
    case Repo.get_by(CanvasAccess, canvas_id: canvas_id, user_id: user_id) do
      nil -> {:error, :not_found}
      access -> Repo.delete(access)
    end
  end

  @doc """
  List all access entries for a canvas, preloading users.
  """
  def list_access(canvas_id) do
    CanvasAccess
    |> where([a], a.canvas_id == ^canvas_id)
    |> preload(:user)
    |> Repo.all()
  end
end
