defmodule TimelessUI.TelemetryAuth.SigningKey do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:kid, :string, autogenerate: false}
  schema "telemetry_auth_keys" do
    field :public_key, :binary
    field :encrypted_private_key, :binary
    field :nonce, :binary
    field :state, :string
    field :not_before, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(key, attrs) do
    key
    |> cast(attrs, [
      :kid,
      :public_key,
      :encrypted_private_key,
      :nonce,
      :state,
      :not_before,
      :expires_at
    ])
    |> validate_required([
      :kid,
      :public_key,
      :encrypted_private_key,
      :nonce,
      :state,
      :not_before,
      :expires_at
    ])
    |> validate_length(:kid, min: 1, max: 255)
    |> validate_inclusion(:state, ["active", "retired", "revoked"])
    |> validate_change(:public_key, fn :public_key, value ->
      if byte_size(value) == 32, do: [], else: [public_key: "must be an Ed25519 public key"]
    end)
    |> validate_change(:nonce, fn :nonce, value ->
      if byte_size(value) == 12, do: [], else: [nonce: "must be 12 bytes"]
    end)
    |> validate_change(:encrypted_private_key, fn :encrypted_private_key, value ->
      if byte_size(value) >= 48,
        do: [],
        else: [encrypted_private_key: "must contain authenticated ciphertext"]
    end)
    |> validate_validity_window()
    |> unique_constraint(:state, name: :telemetry_auth_keys_one_active)
  end

  defp validate_validity_window(changeset) do
    not_before = get_field(changeset, :not_before)
    expires_at = get_field(changeset, :expires_at)
    now = DateTime.utc_now()

    cond do
      not is_struct(not_before, DateTime) or not is_struct(expires_at, DateTime) ->
        changeset

      DateTime.compare(not_before, now) == :gt ->
        add_error(changeset, :not_before, "cannot be in the future")

      DateTime.compare(expires_at, not_before) != :gt ->
        add_error(changeset, :expires_at, "must be after not_before")

      true ->
        changeset
    end
  end
end
