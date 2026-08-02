defmodule TimelessUI.TelemetryAuthTest do
  use TimelessUI.DataCase, async: false

  import Bitwise

  alias TimelessUI.AccountsFixtures
  alias TimelessUI.Repo
  alias TimelessUI.TelemetryAuth
  alias TimelessUI.TelemetryAuth.{Audit, Policy, Revocation, SigningKey}
  alias TimelessUI.TelemetryDataPlane.Policy, as: RuntimePolicy

  setup do
    admin = AccountsFixtures.user_fixture(%{role: "admin"})
    viewer = AccountsFixtures.user_fixture(%{role: "viewer"})

    root = Path.join(System.tmp_dir!(), "telemetry-auth-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      admin: AccountsFixtures.user_scope_fixture(admin),
      viewer: AccountsFixtures.user_scope_fixture(viewer),
      root: root
    }
  end

  test "admin issuance keeps signing material encrypted and publishes public policy only", ctx do
    assert {:error, :forbidden} = TelemetryAuth.rotate_key(ctx.viewer, kid: "viewer-key")
    assert {:ok, key} = TelemetryAuth.rotate_key(ctx.admin, kid: "release-key-1")
    assert key.state == "active"
    assert byte_size(key.public_key) == 32
    refute key.encrypted_private_key == key.public_key
    assert byte_size(key.encrypted_private_key) > 32

    assert {:ok, policy} =
             TelemetryAuth.put_policy(ctx.admin, %{
               subject: "collector-a",
               tenant: "tenant-a",
               signal: :metrics,
               scopes: ~w(metrics:read metrics:write metrics:stats),
               limits: %{"max_query_rows" => 500}
             })

    assert policy.auth_version == 1

    assert {:ok, issued} =
             TelemetryAuth.issue_token(ctx.admin, "collector-a", :metrics,
               tenant: "tenant-a",
               scopes: ~w(metrics:read metrics:stats),
               limits: %{"max_query_rows" => 100},
               expires_in: 120
             )

    assert {:ok, header, claims, signature, signing_input} = decode_token(issued.token)
    assert header == %{"alg" => "EdDSA", "kid" => "release-key-1", "typ" => "JWT"}
    assert claims["sub"] == "collector-a"
    assert claims["tenant"] == "tenant-a"
    assert claims["signal"] == "metrics"
    assert claims["scopes"] == ~w(metrics:read metrics:stats)
    assert claims["limits"]["max_query_rows"] == 100

    assert :crypto.verify(
             :eddsa,
             :none,
             signing_input,
             signature,
             [key.public_key, :ed25519]
           )

    path = Path.join(ctx.root, "metrics-policy.json")
    assert :ok = TelemetryAuth.publish_policy(:metrics, path, tenant: "tenant-a")
    assert {:ok, stat} = File.stat(path)
    assert band(stat.mode, 0o777) == 0o600

    document = path |> File.read!() |> Jason.decode!()
    assert document["subjects"]["collector-a"]["auth_version"] == 1
    assert [%{"kid" => "release-key-1"}] = document["keys"]
    refute Map.has_key?(hd(document["keys"]), "private_key")
    refute File.read!(path) =~ Base.url_encode64(key.encrypted_private_key, padding: false)
    refute File.read!(path) =~ issued.token

    assert Repo.aggregate(Audit, :count) == 3

    assert Enum.sort(Repo.all(from audit in Audit, select: audit.action)) ==
             Enum.sort(~w(key.rotate policy.put token.issue))
  end

  test "rotation, revocation, and auth-version changes are explicit and audited", ctx do
    assert {:ok, first} = TelemetryAuth.rotate_key(ctx.admin, kid: "key-old")

    assert {:ok, _policy} =
             TelemetryAuth.put_policy(ctx.admin, %{
               subject: "collector-b",
               tenant: "default",
               signal: "logs",
               scopes: ~w(logs:read logs:write logs:stats logs:maintenance)
             })

    assert {:ok, issued} = TelemetryAuth.issue_token(ctx.admin, "collector-b", :logs)
    assert {:ok, second} = TelemetryAuth.rotate_key(ctx.admin, kid: "key-new")
    assert Repo.get!(SigningKey, first.kid).state == "retired"
    assert second.state == "active"

    assert {:ok, changed} =
             TelemetryAuth.bump_auth_version(ctx.admin, "collector-b", "default", :logs)

    assert changed.auth_version == 2

    assert {:ok, %Revocation{jti: jti}} =
             TelemetryAuth.revoke_token(ctx.admin, issued.token, "lost")

    assert jti == issued.claims["jti"]
    assert {:ok, %SigningKey{state: "revoked"}} = TelemetryAuth.revoke_key(ctx.admin, second.kid)

    path = Path.join(ctx.root, "logs-policy.json")
    assert :ok = TelemetryAuth.publish_policy(:logs, path)
    document = path |> File.read!() |> Jason.decode!()
    assert document["subjects"]["collector-b"]["auth_version"] == 2
    assert jti in document["revoked_jtis"]
    assert Enum.find(document["keys"], &(&1["kid"] == "key-new"))["revoked"]
    refute Enum.find(document["keys"], &(&1["kid"] == "key-old"))["revoked"]
  end

  test "issuance rejects absent/disabled policy, excess scopes, limits, and lifetime", ctx do
    assert {:ok, _key} = TelemetryAuth.rotate_key(ctx.admin)
    assert {:error, :unknown_policy} = TelemetryAuth.issue_token(ctx.admin, "missing", :traces)

    assert {:ok, _policy} =
             TelemetryAuth.put_policy(ctx.admin, %{
               subject: "limited",
               tenant: "default",
               signal: "traces",
               scopes: ~w(traces:read),
               limits: %{"max_query_rows" => 10},
               enabled: true
             })

    assert {:error, :scope_denied} =
             TelemetryAuth.issue_token(ctx.admin, "limited", :traces, scopes: ~w(traces:write))

    assert {:error, :limit_denied} =
             TelemetryAuth.issue_token(ctx.admin, "limited", :traces,
               limits: %{"max_query_rows" => 11}
             )

    assert {:error, :unsupported_limit} =
             TelemetryAuth.issue_token(ctx.admin, "limited", :traces,
               limits: %{"surprise_limit" => 1}
             )

    assert {:error, :invalid_token_lifetime} =
             TelemetryAuth.issue_token(ctx.admin, "limited", :traces, expires_in: 901)

    assert {:ok, %Policy{enabled: false}} =
             TelemetryAuth.put_policy(ctx.admin, %{
               subject: "limited",
               tenant: "default",
               signal: "traces",
               scopes: ~w(traces:read),
               enabled: false
             })

    assert {:error, :policy_disabled} =
             TelemetryAuth.issue_token(ctx.admin, "limited", :traces)

    assert {:error, :unsupported_signal} =
             TelemetryAuth.issue_token(ctx.admin, "limited", :profiles)
  end

  test "runtime policy owner supplies tokens without exposing credentials in status", ctx do
    path = Path.join(ctx.root, "traces-public-policy.json")
    name = :telemetry_runtime_policy_test

    start_supervised!(
      {RuntimePolicy,
       name: name,
       planes: [
         [signal: :traces, auth_mode: :required, auth_policy_path: path, tenant: "default"]
       ]}
    )

    assert {:ok, {"authorization", "Bearer " <> token}} =
             RuntimePolicy.authorization_header(:traces, name)

    assert length(String.split(token, ".")) == 3
    status = RuntimePolicy.status(name)
    assert status.traces.ready
    assert status.traces.token_cached
    refute inspect(status) =~ token
    refute File.read!(path) =~ token
    assert Repo.get_by!(Policy, subject: "timeless-ui:traces").signal == "traces"
  end

  defp decode_token(token) do
    with [encoded_header, encoded_claims, encoded_signature] <- String.split(token, "."),
         {:ok, header_json} <- Base.url_decode64(encoded_header, padding: false),
         {:ok, claims_json} <- Base.url_decode64(encoded_claims, padding: false),
         {:ok, signature} <- Base.url_decode64(encoded_signature, padding: false),
         {:ok, header} <- Jason.decode(header_json),
         {:ok, claims} <- Jason.decode(claims_json) do
      {:ok, header, claims, signature, encoded_header <> "." <> encoded_claims}
    end
  end
end
