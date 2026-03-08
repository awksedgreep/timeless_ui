defmodule TimelessUI.Poller.Host do
  use Ecto.Schema
  import Ecto.Changeset

  schema "poller_hosts" do
    field :name, :string
    field :ip, :string
    field :type, :string, default: "generic"
    field :status, :string, default: "active"
    field :config, :map, default: %{}
    field :tags, :string, default: ""

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name ip)a
  @optional_fields ~w(type status config tags)a

  def changeset(host, attrs) do
    host
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:name)
  end

  @doc "Returns the list of tags as a list of trimmed strings."
  def tags_list(%__MODULE__{tags: tags}) when is_binary(tags) do
    tags
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  def tags_list(%__MODULE__{}), do: []

  @doc "Returns true if the host has the given tag."
  def has_tag?(%__MODULE__{} = host, tag) when is_binary(tag) do
    tag in tags_list(host)
  end

  @doc "Returns true if the host has any of the given tags."
  def has_any_tag?(%__MODULE__{} = host, tags) when is_list(tags) do
    host_tags = tags_list(host)
    Enum.any?(tags, &(&1 in host_tags))
  end

  def has_any_tag?(%__MODULE__{}, _), do: true
end
