defmodule TimelessUI.Poller.Host do
  use Ecto.Schema
  import Ecto.Changeset

  schema "poller_hosts" do
    field :name, :string
    field :ip, :string
    field :type, :string, default: "generic"
    field :status, :string, default: "active"
    field :config, :map, default: %{}
    field :groups, :map, default: %{}
    field :tags, :string, default: "[]"

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name ip)a
  @optional_fields ~w(type status config groups tags)a

  def changeset(host, attrs) do
    host
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:name)
  end

  @doc """
  Returns true if the host belongs to the given group.
  Groups are stored as `%{"group_key" => "group_value"}`.
  """
  def in_group?(%__MODULE__{groups: groups}, {key, value}) do
    Map.get(groups, to_string(key)) == to_string(value)
  end

  def in_group?(%__MODULE__{groups: groups}, group_name) when is_binary(group_name) do
    Map.has_key?(groups, group_name)
  end

  @doc """
  Returns true if the host matches any of the given group criteria.
  `group_criteria` is a map like `%{"region" => "us-east", "role" => "router"}`.
  A host matches if it has at least one matching key-value pair.
  """
  def matches_any_group?(%__MODULE__{} = host, group_criteria) when is_map(group_criteria) do
    Enum.any?(group_criteria, fn {key, value} ->
      in_group?(host, {key, value})
    end)
  end

  def matches_any_group?(%__MODULE__{}, criteria) when criteria in [nil, %{}], do: true
end
