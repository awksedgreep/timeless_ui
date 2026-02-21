defmodule TimelessUI.Canvases.CanvasRecord do
  use Ecto.Schema
  import Ecto.Changeset

  schema "canvases" do
    field :name, :string
    field :data, :map

    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:name, :data])
    |> validate_required([:name, :data])
    |> unique_constraint(:name)
  end
end
