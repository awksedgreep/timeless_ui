defmodule TimelessUI.TelemetryAuth.Policy do
  use Ecto.Schema
  import Ecto.Changeset

  @operations ~w(read write stats maintenance)
  @limit_names ~w(max_request_bytes max_decompressed_bytes max_response_bytes max_query_rows max_request_ms max_concurrent_requests max_queue_ms)

  schema "telemetry_auth_policies" do
    field :subject, :string
    field :tenant, :string
    field :signal, :string
    field :scopes, :map
    field :limits, :map
    field :auth_version, :integer, default: 1
    field :enabled, :boolean, default: true
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [:subject, :tenant, :signal, :scopes, :limits, :auth_version, :enabled])
    |> validate_required([:subject, :tenant, :signal, :scopes, :limits, :auth_version, :enabled])
    |> validate_length(:subject, min: 1, max: 255)
    |> validate_length(:tenant, min: 1, max: 255)
    |> validate_inclusion(:signal, ["metrics", "logs", "traces"])
    |> validate_number(:auth_version, greater_than: 0)
    |> validate_scopes()
    |> validate_limits()
    |> unique_constraint([:subject, :tenant, :signal])
  end

  defp validate_scopes(changeset) do
    validate_change(changeset, :scopes, fn :scopes, scopes ->
      case scopes do
        %{"values" => values} when is_list(values) and values != [] ->
          signal = get_field(changeset, :signal)

          allowed = Enum.map(@operations, &"#{signal}:#{&1}")

          if Enum.all?(values, &(&1 in allowed)) do
            []
          else
            [scopes: "must contain only scopes for the selected signal"]
          end

        _ ->
          [scopes: "must contain at least one scope"]
      end
    end)
  end

  defp validate_limits(changeset) do
    validate_change(changeset, :limits, fn :limits, limits ->
      if is_map(limits) and Map.keys(limits) |> Enum.sort() == Enum.sort(@limit_names) and
           Enum.all?(limits, fn {name, value} ->
             is_binary(name) and is_integer(value) and value > 0
           end) do
        []
      else
        [limits: "must contain positive integer limits"]
      end
    end)
  end
end
