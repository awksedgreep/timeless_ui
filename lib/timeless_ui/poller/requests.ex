defmodule TimelessUI.Poller.Requests do
  import Ecto.Query

  alias TimelessUI.Repo
  alias TimelessUI.Poller.Request

  def list_requests do
    Repo.all(from r in Request, order_by: [asc: r.name])
  end

  def list_requests_by_group(group_criteria) when is_map(group_criteria) do
    list_requests()
    |> Enum.filter(fn request ->
      Enum.any?(group_criteria, fn {key, value} ->
        Map.get(request.groups, to_string(key)) == to_string(value)
      end)
    end)
  end

  def get_request!(id), do: Repo.get!(Request, id)

  def get_request(id) do
    case Repo.get(Request, id) do
      nil -> {:error, :not_found}
      request -> {:ok, request}
    end
  end

  def create_request(attrs \\ %{}) do
    %Request{}
    |> Request.changeset(attrs)
    |> Repo.insert()
  end

  def update_request(%Request{} = request, attrs) do
    request
    |> Request.changeset(attrs)
    |> Repo.update()
  end

  def delete_request(%Request{} = request) do
    Repo.delete(request)
  end

  def change_request(%Request{} = request, attrs \\ %{}) do
    Request.changeset(request, attrs)
  end
end
