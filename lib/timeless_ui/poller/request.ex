defmodule TimelessUI.Poller.Request do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_types ~w(icmp_ping prometheus snmpget snmpwalk snmpbulkwalk mikrotik_rest)

  schema "poller_requests" do
    field :name, :string
    field :type, :string
    field :groups, :map, default: %{}
    field :config, :map, default: %{}
    field :description, :string

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name type)a
  @optional_fields ~w(groups config description)a

  def changeset(request, attrs) do
    request
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:type, @valid_types)
    |> unique_constraint(:name)
  end

  def valid_types, do: @valid_types
end
