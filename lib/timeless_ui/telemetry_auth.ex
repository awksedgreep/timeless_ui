defmodule TimelessUI.TelemetryAuth do
  @moduledoc """
  Phoenix-owned issuance and policy boundary for the three Rust data planes.

  Private signing material is encrypted at rest and never enters a Rust
  process or exported policy file. Rust receives public keys, per-subject
  authorization versions/scopes/limits, and revocation identifiers only.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias TimelessUI.Accounts.Scope
  alias TimelessUI.Accounts.User
  alias TimelessUI.Repo
  alias TimelessUI.TelemetryAuth.{Audit, Policy, Revocation, SigningKey}

  @signals ~w(metrics logs traces)
  @states ~w(active retired revoked)
  @issuer "timeless-control-plane"
  @audience "timeless-data-plane"
  @tag_bytes 16
  @default_token_seconds 300
  @maximum_token_seconds 900
  @default_limits %{
    "max_request_bytes" => 10 * 1_024 * 1_024,
    "max_decompressed_bytes" => 10 * 1_024 * 1_024,
    "max_response_bytes" => 16 * 1_024 * 1_024,
    "max_query_rows" => 100_000,
    "max_request_ms" => 30_000,
    "max_concurrent_requests" => 64,
    "max_queue_ms" => 1_000
  }

  def default_limits, do: @default_limits

  def rotate_key(%Scope{} = current_scope, opts \\ []) do
    with :ok <- authorize_admin(current_scope) do
      do_rotate_key(opts, actor(current_scope))
    end
  end

  @doc false
  def rotate_key_system(opts \\ []), do: do_rotate_key(opts, system_actor())

  defp do_rotate_key(opts, audit_actor) do
    now = now()
    expires_at = Keyword.get(opts, :expires_at, DateTime.add(now, 30 * 24 * 60 * 60, :second))
    kid = Keyword.get(opts, :kid, random_id(12))
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    {encrypted, nonce} = encrypt_private_key(kid, private)

    attrs = %{
      kid: kid,
      public_key: public,
      encrypted_private_key: encrypted,
      nonce: nonce,
      state: "active",
      not_before: Keyword.get(opts, :not_before, now),
      expires_at: expires_at
    }

    Multi.new()
    |> Multi.update_all(
      :retire_active,
      from(key in SigningKey, where: key.state == "active"),
      set: [state: "retired", updated_at: now]
    )
    |> Multi.insert(:key, SigningKey.changeset(%SigningKey{}, attrs))
    |> Multi.run(:audit, fn repo, %{key: key} ->
      insert_audit(repo, audit_actor, "key.rotate", %{kid: key.kid})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{key: key}} -> {:ok, key}
      {:error, _operation, reason, _changes} -> {:error, reason}
    end
  end

  def revoke_key(%Scope{} = current_scope, kid) when is_binary(kid) do
    with :ok <- authorize_admin(current_scope) do
      do_revoke_key(kid, actor(current_scope))
    end
  end

  defp do_revoke_key(kid, audit_actor) do
    with %SigningKey{} = key <- Repo.get(SigningKey, kid) do
      Multi.new()
      |> Multi.update(:key, SigningKey.changeset(key, %{state: "revoked"}))
      |> Multi.run(:audit, fn repo, _changes ->
        insert_audit(repo, audit_actor, "key.revoke", %{kid: kid})
      end)
      |> Repo.transaction()
      |> transaction_result(:key)
    else
      nil -> {:error, :unknown_key}
    end
  end

  def put_policy(%Scope{} = current_scope, attrs) when is_map(attrs) do
    with :ok <- authorize_admin(current_scope) do
      do_put_policy(attrs, actor(current_scope))
    end
  end

  @doc false
  def put_policy_system(attrs) when is_map(attrs), do: do_put_policy(attrs, system_actor())

  defp do_put_policy(attrs, audit_actor) do
    attrs = normalize_policy_attrs(attrs)

    existing =
      Repo.get_by(Policy,
        subject: fetch(attrs, :subject),
        tenant: fetch(attrs, :tenant),
        signal: fetch(attrs, :signal)
      ) || %Policy{}

    Multi.new()
    |> Multi.insert_or_update(:policy, Policy.changeset(existing, attrs))
    |> Multi.run(:audit, fn repo, %{policy: policy} ->
      insert_audit(repo, audit_actor, "policy.put", policy_identity(policy))
    end)
    |> Repo.transaction()
    |> transaction_result(:policy)
  end

  def bump_auth_version(%Scope{} = current_scope, subject, tenant, signal) do
    with :ok <- authorize_admin(current_scope) do
      do_bump_auth_version(subject, tenant, signal, actor(current_scope))
    end
  end

  defp do_bump_auth_version(subject, tenant, signal, audit_actor) do
    case Repo.get_by(Policy, subject: subject, tenant: tenant, signal: to_string(signal)) do
      %Policy{} = policy ->
        Multi.new()
        |> Multi.update(
          :policy,
          Policy.changeset(policy, %{auth_version: policy.auth_version + 1})
        )
        |> Multi.run(:audit, fn repo, %{policy: changed} ->
          insert_audit(
            repo,
            audit_actor,
            "policy.bump_auth_version",
            Map.put(policy_identity(changed), :details, %{"auth_version" => changed.auth_version})
          )
        end)
        |> Repo.transaction()
        |> transaction_result(:policy)

      nil ->
        {:error, :unknown_policy}
    end
  end

  def issue_token(%Scope{} = current_scope, subject, signal, opts \\ []) do
    with :ok <- authorize_admin(current_scope) do
      do_issue_token(subject, signal, opts, actor(current_scope))
    end
  end

  @doc false
  def issue_token_system(subject, signal, opts \\ []) do
    do_issue_token(subject, signal, opts, system_actor())
  end

  defp do_issue_token(subject, signal, opts, audit_actor) do
    signal = to_string(signal)
    tenant = Keyword.get(opts, :tenant, "default")
    requested_scopes = Keyword.get(opts, :scopes)
    requested_limits = stringify_keys(Keyword.get(opts, :limits, %{}))
    ttl = Keyword.get(opts, :expires_in, @default_token_seconds)

    with :ok <- validate_signal(signal),
         :ok <- validate_ttl(ttl),
         {:ok, policy} <- fetch_enabled_policy(to_string(subject), tenant, signal),
         {:ok, scopes} <- select_scopes(requested_scopes, policy.scopes),
         {:ok, limits} <- select_limits(requested_limits, policy.limits),
         %SigningKey{} = key <- active_key(),
         {:ok, private} <- decrypt_private_key(key) do
      issued_at = System.system_time(:second)

      claims = %{
        "iss" => @issuer,
        "aud" => @audience,
        "sub" => to_string(subject),
        "jti" => random_id(18),
        "tenant" => tenant,
        "signal" => signal,
        "scopes" => scopes,
        "auth_version" => policy.auth_version,
        "iat" => issued_at,
        "nbf" => issued_at,
        "exp" => issued_at + ttl,
        "limits" => limits
      }

      token = sign_token(claims, key.kid, private)

      case insert_audit(Repo, audit_actor, "token.issue", %{
             subject: claims["sub"],
             tenant: tenant,
             signal: signal,
             kid: key.kid,
             jti: claims["jti"],
             details: %{"expires_at" => claims["exp"], "scopes" => scopes}
           }) do
        {:ok, _audit} -> {:ok, %{token: token, claims: claims, kid: key.kid}}
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :no_active_signing_key}
      {:error, _} = error -> error
    end
  end

  def revoke_token(%Scope{} = current_scope, token, reason \\ nil) when is_binary(token) do
    with :ok <- authorize_admin(current_scope) do
      do_revoke_token(token, reason, actor(current_scope))
    end
  end

  defp do_revoke_token(token, reason, audit_actor) do
    with {:ok, claims} <- verify_issued_token(token),
         %{"jti" => jti, "exp" => expires} <- claims,
         {:ok, expires_at} <- DateTime.from_unix(expires) do
      Multi.new()
      |> Multi.insert(
        :revocation,
        Revocation.changeset(%Revocation{}, %{jti: jti, expires_at: expires_at, reason: reason}),
        on_conflict: :nothing
      )
      |> Multi.run(:audit, fn repo, _changes ->
        insert_audit(repo, audit_actor, "token.revoke", %{
          subject: claims["sub"],
          tenant: claims["tenant"],
          signal: claims["signal"],
          jti: jti,
          details: %{"reason" => reason}
        })
      end)
      |> Repo.transaction()
      |> transaction_result(:revocation)
    else
      _ -> {:error, :invalid_token}
    end
  end

  @doc false
  def ensure_runtime_policy(signal, path, opts \\ []) do
    signal = to_string(signal)
    tenant = Keyword.get(opts, :tenant, "default")
    subject = service_subject(signal)

    with :ok <- validate_signal(signal),
         {:ok, _key} <- ensure_active_key(),
         {:ok, _policy} <-
           put_policy_system(%{
             subject: subject,
             tenant: tenant,
             signal: signal,
             scopes: Enum.map(~w(read write stats maintenance), &"#{signal}:#{&1}"),
             limits: configured_maximum_limits(),
             enabled: true
           }),
         :ok <- publish_policy(signal, path, tenant: tenant) do
      {:ok, %{subject: subject, tenant: tenant, signal: signal, policy_path: Path.expand(path)}}
    end
  end

  @doc false
  def issue_runtime_token(signal, opts \\ []) do
    signal = to_string(signal)
    tenant = Keyword.get(opts, :tenant, "default")
    issue_token_system(service_subject(signal), signal, tenant: tenant)
  end

  def publish_policy(signal, path, opts \\ []) do
    signal = to_string(signal)
    tenant = Keyword.get(opts, :tenant, "default")
    now = now()

    with :ok <- validate_signal(signal),
         policies when policies != [] <-
           Repo.all(
             from policy in Policy,
               where:
                 policy.signal == ^signal and policy.tenant == ^tenant and policy.enabled == true,
               order_by: [asc: policy.subject]
           ),
         keys when keys != [] <-
           Repo.all(
             from key in SigningKey,
               where: key.state in ^@states and key.expires_at > ^now,
               order_by: [asc: key.kid]
           ) do
      document = %{
        "version" => 1,
        "issuer" => @issuer,
        "audience" => @audience,
        "tenant" => tenant,
        "minimum_auth_version" => Enum.min_by(policies, & &1.auth_version).auth_version,
        "max_token_seconds" => @maximum_token_seconds,
        "maximum_limits" => configured_maximum_limits(),
        "subjects" => Map.new(policies, &subject_document/1),
        "keys" => Enum.map(keys, &key_document/1),
        "revoked_jtis" => active_revocations(now)
      }

      atomic_write_json(path, document)
    else
      [] -> {:error, :authorization_policy_incomplete}
      {:error, _} = error -> error
    end
  end

  def prune_revocations do
    {deleted, _} =
      Repo.delete_all(from revocation in Revocation, where: revocation.expires_at <= ^now())

    {:ok, deleted}
  end

  defp active_key do
    current = now()

    Repo.one(
      from key in SigningKey,
        where: key.state == "active" and key.not_before <= ^current and key.expires_at > ^current,
        limit: 1
    )
  end

  defp ensure_active_key do
    case active_key() do
      %SigningKey{} = key -> {:ok, key}
      nil -> rotate_key_system()
    end
  end

  defp verify_issued_token(token) do
    with [encoded_header, encoded_claims, encoded_signature] <- String.split(token, "."),
         {:ok, header_json} <- Base.url_decode64(encoded_header, padding: false),
         {:ok, claims_json} <- Base.url_decode64(encoded_claims, padding: false),
         {:ok, signature} <- Base.url_decode64(encoded_signature, padding: false),
         {:ok, %{"alg" => "EdDSA", "kid" => kid}} <- Jason.decode(header_json),
         {:ok, claims} <- Jason.decode(claims_json),
         %SigningKey{} = key <- Repo.get(SigningKey, kid),
         true <-
           :crypto.verify(
             :eddsa,
             :none,
             encoded_header <> "." <> encoded_claims,
             signature,
             [key.public_key, :ed25519]
           ) do
      {:ok, claims}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp encrypt_private_key(kid, private) do
    nonce = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        encryption_key(),
        nonce,
        private,
        kid,
        @tag_bytes,
        true
      )

    {ciphertext <> tag, nonce}
  end

  defp decrypt_private_key(%SigningKey{} = key) do
    size = byte_size(key.encrypted_private_key) - @tag_bytes

    if size > 0 do
      <<ciphertext::binary-size(^size), tag::binary-size(@tag_bytes)>> =
        key.encrypted_private_key

      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             encryption_key(),
             key.nonce,
             ciphertext,
             key.kid,
             tag,
             false
           ) do
        :error -> {:error, :signing_key_decryption_failed}
        private -> {:ok, private}
      end
    else
      {:error, :signing_key_decryption_failed}
    end
  end

  defp encryption_key do
    secret =
      Application.get_env(:timeless_ui, :telemetry_auth_encryption_secret) ||
        Application.fetch_env!(:timeless_ui, TimelessUIWeb.Endpoint)[:secret_key_base]

    :crypto.hash(:sha256, secret)
  end

  defp select_scopes(nil, %{"values" => scopes}), do: {:ok, scopes}

  defp select_scopes(requested, %{"values" => allowed}) when is_list(requested) do
    requested = Enum.map(requested, &to_string/1) |> Enum.uniq() |> Enum.sort()

    if requested != [] and Enum.all?(requested, &(&1 in allowed)),
      do: {:ok, requested},
      else: {:error, :scope_denied}
  end

  defp select_scopes(_, _), do: {:error, :invalid_policy_scopes}

  defp fetch_enabled_policy(subject, tenant, signal) do
    case Repo.get_by(Policy, subject: subject, tenant: tenant, signal: signal) do
      %Policy{enabled: true} = policy -> {:ok, policy}
      %Policy{enabled: false} -> {:error, :policy_disabled}
      nil -> {:error, :unknown_policy}
    end
  end

  defp select_limits(requested, allowed) when is_map(allowed) do
    supported = Map.keys(@default_limits) |> MapSet.new()

    if Map.keys(requested) |> MapSet.new() |> MapSet.subset?(supported) do
      limits = Map.merge(allowed, requested)

      if Enum.all?(@default_limits, fn {name, _} ->
           is_integer(limits[name]) and limits[name] > 0 and limits[name] <= allowed[name]
         end) do
        {:ok, Map.take(limits, Map.keys(@default_limits))}
      else
        {:error, :limit_denied}
      end
    else
      {:error, :unsupported_limit}
    end
  end

  defp normalize_policy_attrs(attrs) do
    scopes = fetch(attrs, :scopes)
    limits = Map.merge(@default_limits, stringify_keys(fetch(attrs, :limits) || %{}))

    attrs
    |> stringify_keys()
    |> Map.put("signal", to_string(fetch(attrs, :signal)))
    |> Map.put("subject", to_string(fetch(attrs, :subject)))
    |> Map.put("tenant", to_string(fetch(attrs, :tenant)))
    |> Map.put("scopes", %{
      "values" => scopes |> List.wrap() |> Enum.map(&to_string/1) |> Enum.uniq() |> Enum.sort()
    })
    |> Map.put("limits", limits)
  end

  defp subject_document(policy) do
    {policy.subject,
     %{
       "auth_version" => policy.auth_version,
       "scopes" => policy.scopes["values"],
       "maximum_limits" => policy.limits,
       "enabled" => policy.enabled
     }}
  end

  defp key_document(key) do
    %{
      "kid" => key.kid,
      "public_key" => Base.url_encode64(key.public_key, padding: false),
      "not_before" => DateTime.to_unix(key.not_before),
      "expires_at" => DateTime.to_unix(key.expires_at),
      "revoked" => key.state == "revoked"
    }
  end

  defp active_revocations(current) do
    Repo.all(
      from revocation in Revocation,
        where: revocation.expires_at > ^current,
        order_by: [asc: revocation.jti],
        select: revocation.jti
    )
  end

  defp atomic_write_json(path, document) do
    path = Path.expand(path)
    :ok = File.mkdir_p(Path.dirname(path))
    temporary = path <> ".tmp.#{System.unique_integer([:positive])}"

    with {:ok, json} <- Jason.encode(document),
         :ok <- File.write(temporary, json, [:binary, :sync]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      error ->
        _ = File.rm(temporary)
        error
    end
  end

  defp configured_maximum_limits do
    @default_limits
    |> Map.merge(
      stringify_keys(Application.get_env(:timeless_ui, :telemetry_data_plane_maximum_limits, %{}))
    )
  end

  defp validate_signal(signal) when signal in @signals, do: :ok
  defp validate_signal(_), do: {:error, :unsupported_signal}

  defp validate_ttl(ttl) when is_integer(ttl) and ttl in 1..@maximum_token_seconds, do: :ok
  defp validate_ttl(_), do: {:error, :invalid_token_lifetime}

  defp authorize_admin(%Scope{user: %User{} = user}) do
    if User.admin?(user), do: :ok, else: {:error, :forbidden}
  end

  defp authorize_admin(_scope), do: {:error, :forbidden}

  defp actor(%Scope{user: %User{} = user}) do
    %{actor_type: "user", actor_identifier: Integer.to_string(user.id)}
  end

  defp system_actor, do: %{actor_type: "system", actor_identifier: "timeless_ui"}

  defp insert_audit(repo, audit_actor, action, attrs) do
    attrs = Map.new(attrs)

    %Audit{}
    |> Audit.changeset(
      audit_actor
      |> Map.put(:action, action)
      |> Map.put(:subject, Map.get(attrs, :subject))
      |> Map.put(:tenant, Map.get(attrs, :tenant))
      |> Map.put(:signal, Map.get(attrs, :signal))
      |> Map.put(:kid, Map.get(attrs, :kid))
      |> Map.put(:jti, Map.get(attrs, :jti))
      |> Map.put(:details, Map.get(attrs, :details, %{}))
    )
    |> repo.insert()
  end

  defp policy_identity(policy) do
    %{subject: policy.subject, tenant: policy.tenant, signal: policy.signal}
  end

  defp transaction_result({:ok, changes}, name), do: {:ok, Map.fetch!(changes, name)}

  defp transaction_result({:error, _operation, reason, _changes}, _name),
    do: {:error, reason}

  defp service_subject(signal), do: "timeless-ui:#{signal}"

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp stringify_keys(_), do: %{}
  @doc """
  The complete wire construction for a data-plane token: claims map + kid +
  raw Ed25519 private key -> signed compact JWS. Pure and deterministic so
  the cross-implementation conformance fixture can pin the exact bytes this
  minter produces — the Rust verifier in timeless-libsql
  (`servers/crates/timeless-api-common/tests/conformance.rs`) accepts a
  golden token generated by this function, and `timeless-authctl` is the
  independent Rust producer of the same format. Change the wire shape here
  and the golden test below fails before production does.
  """
  def sign_token(claims, kid, private) do
    header = %{"alg" => "EdDSA", "kid" => kid, "typ" => "JWT"}
    signing_input = encoded(header) <> "." <> encoded(claims)
    signature = :crypto.sign(:eddsa, :none, signing_input, [private, :ed25519])
    signing_input <> "." <> Base.url_encode64(signature, padding: false)
  end

  defp encoded(value), do: value |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp random_id(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
