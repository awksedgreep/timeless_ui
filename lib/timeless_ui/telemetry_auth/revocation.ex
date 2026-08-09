defmodule TimelessUI.TelemetryAuth.Revocation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:jti, :string, autogenerate: false}
  schema "telemetry_auth_revocations" do
    field :expires_at, :utc_datetime_usec
    field :reason, :string
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(revocation, attrs) do
    revocation
    |> cast(attrs, [:jti, :expires_at, :reason])
    |> validate_required([:jti, :expires_at])
    |> validate_length(:jti, min: 1, max: 255)
    |> validate_length(:reason, max: 1_024)
    |> unique_constraint(:jti)
  end
end
