defmodule TimelessUI.Repo.Migrations.CreateTelemetryAuthTables do
  use Ecto.Migration

  def change do
    create table(:telemetry_auth_keys, primary_key: false) do
      add :kid, :string, primary_key: true
      add :public_key, :binary, null: false
      add :encrypted_private_key, :binary, null: false
      add :nonce, :binary, null: false
      add :state, :string, null: false
      add :not_before, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:telemetry_auth_keys, [:state],
             where: "state = 'active'",
             name: :telemetry_auth_keys_one_active
           )

    create table(:telemetry_auth_policies) do
      add :subject, :string, null: false
      add :tenant, :string, null: false
      add :signal, :string, null: false
      add :scopes, :map, null: false
      add :limits, :map, null: false
      add :auth_version, :integer, null: false, default: 1
      add :enabled, :boolean, null: false, default: true
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:telemetry_auth_policies, [:subject, :tenant, :signal])

    create table(:telemetry_auth_revocations, primary_key: false) do
      add :jti, :string, primary_key: true
      add :expires_at, :utc_datetime_usec, null: false
      add :reason, :string
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create index(:telemetry_auth_revocations, [:expires_at])

    create table(:telemetry_auth_audits) do
      add :actor_type, :string, null: false
      add :actor_identifier, :string, null: false
      add :action, :string, null: false
      add :subject, :string
      add :tenant, :string
      add :signal, :string
      add :kid, :string
      add :jti, :string
      add :details, :map, null: false, default: %{}
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create index(:telemetry_auth_audits, [:inserted_at])
    create index(:telemetry_auth_audits, [:subject, :tenant, :signal])
  end
end
