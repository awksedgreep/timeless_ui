defmodule TimelessUI.Poller.Hosts do
  import Ecto.Query

  alias TimelessUI.Repo
  alias TimelessUI.Poller.Host

  def list_hosts do
    Repo.all(from h in Host, order_by: [asc: h.name])
  end

  def list_hosts_by_group(group_criteria) when is_map(group_criteria) do
    list_hosts()
    |> Enum.filter(&Host.matches_any_group?(&1, group_criteria))
  end

  def get_host!(id), do: Repo.get!(Host, id)

  def get_host(id) do
    case Repo.get(Host, id) do
      nil -> {:error, :not_found}
      host -> {:ok, host}
    end
  end

  def create_host(attrs \\ %{}) do
    %Host{}
    |> Host.changeset(attrs)
    |> Repo.insert()
  end

  def update_host(%Host{} = host, attrs) do
    host
    |> Host.changeset(attrs)
    |> Repo.update()
  end

  def delete_host(%Host{} = host) do
    Repo.delete(host)
  end

  def change_host(%Host{} = host, attrs \\ %{}) do
    Host.changeset(host, attrs)
  end
end
