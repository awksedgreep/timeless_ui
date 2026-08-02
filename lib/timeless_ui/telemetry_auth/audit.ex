defmodule TimelessUI.TelemetryAuth.Audit do
  use Ecto.Schema
  import Ecto.Changeset

  schema "telemetry_auth_audits" do
    field :actor_type, :string
    field :actor_identifier, :string
    field :action, :string
    field :subject, :string
    field :tenant, :string
    field :signal, :string
    field :kid, :string
    field :jti, :string
    field :details, :map, default: %{}
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(audit, attrs) do
    audit
    |> cast(attrs, [
      :actor_type,
      :actor_identifier,
      :action,
      :subject,
      :tenant,
      :signal,
      :kid,
      :jti,
      :details
    ])
    |> validate_required([:actor_type, :actor_identifier, :action, :details])
  end
end
