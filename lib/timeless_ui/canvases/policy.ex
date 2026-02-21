defmodule TimelessUI.Canvases.Policy do
  @moduledoc """
  Authorization policy for canvas operations.

  Admin users (determined by ADMIN_EMAILS env var) bypass all checks.
  Canvas owners have full control. Editors can view and edit.
  Viewers can only view.
  """

  alias TimelessUI.Canvases.CanvasAccess
  alias TimelessUI.Repo

  import Ecto.Query

  @doc """
  Returns true if the user's email is in the ADMIN_EMAILS env var.
  ADMIN_EMAILS is a comma-separated list of emails.
  """
  def admin?(%{email: email}) do
    case System.get_env("ADMIN_EMAILS") do
      nil -> false
      "" -> false
      emails -> email in String.split(emails, ",", trim: true)
    end
  end

  @doc """
  Check if a user is authorized to perform an action on a canvas.

  Actions: :view, :edit, :delete, :share

  Returns :ok or {:error, :unauthorized}.
  """
  def authorize(user, canvas_record, action) do
    cond do
      admin?(user) -> :ok
      canvas_record.user_id == user.id -> :ok
      true -> check_access(user.id, canvas_record.id, action)
    end
  end

  defp check_access(user_id, canvas_id, action) do
    case get_role(user_id, canvas_id) do
      nil -> {:error, :unauthorized}
      role -> check_role(role, action)
    end
  end

  defp get_role(user_id, canvas_id) do
    CanvasAccess
    |> where([a], a.user_id == ^user_id and a.canvas_id == ^canvas_id)
    |> select([a], a.role)
    |> Repo.one()
  end

  defp check_role(:owner, _action), do: :ok
  defp check_role(:editor, :view), do: :ok
  defp check_role(:editor, :edit), do: :ok
  defp check_role(:editor, _), do: {:error, :unauthorized}
  defp check_role(:viewer, :view), do: :ok
  defp check_role(:viewer, _), do: {:error, :unauthorized}
end
