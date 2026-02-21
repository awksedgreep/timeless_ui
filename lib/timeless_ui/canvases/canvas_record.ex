defmodule TimelessUI.Canvases.CanvasRecord do
  use Ecto.Schema
  import Ecto.Changeset

  schema "canvases" do
    field :name, :string
    field :data, :map
    belongs_to :user, TimelessUI.Accounts.User

    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:name, :data, :user_id])
    |> validate_required([:name, :data, :user_id])
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :name])
  end
end
