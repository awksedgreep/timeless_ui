defmodule TimelessUI.Poller.Request do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_types ~w(icmp_ping prometheus snmpget snmpwalk snmpbulkwalk mikrotik_rest)

  schema "poller_requests" do
    field :name, :string
    field :type, :string
    field :tags, :string, default: ""
    field :groups, :map, default: %{}
    field :config, :map, default: %{}
    field :description, :string

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name type)a
  @optional_fields ~w(tags groups config description)a

  def changeset(request, attrs) do
    request
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:type, @valid_types)
    |> unique_constraint(:name)
  end

  def valid_types, do: @valid_types

  def tags_list(%__MODULE__{tags: tags}) when is_binary(tags) do
    tags |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

  def tags_list(%__MODULE__{}), do: []

  def has_all_tags?(%__MODULE__{} = request, required_tags) when is_list(required_tags) do
    request_tags = tags_list(request)
    Enum.all?(required_tags, &(&1 in request_tags))
  end

  def has_all_tags?(%__MODULE__{}, _), do: true
end
