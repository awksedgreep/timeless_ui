defmodule TimelessUI.TelemetryAuthConformanceTest do
  use ExUnit.Case, async: true

  # Cross-implementation conformance (timeless-libsql AUTH_OPT_IN_PLAN.md
  # §6.3). TelemetryAuth and timeless-authctl are two independent producers
  # of one token format, reconciled only by the Rust verifier. This golden is
  # committed as `elixir-token.txt` in timeless-libsql's
  # `servers/crates/timeless-api-common/tests/conformance/`, where the
  # verifier's conformance test must accept it. If the wire construction
  # here changes, this test fails BEFORE the Rust side does — regenerate the
  # golden with the fixed inputs below, update both copies, and re-run the
  # Rust conformance test.
  @golden "eyJhbGciOiJFZERTQSIsImtpZCI6ImVhNGE2YzYzZTI5YzUyMGEiLCJ0eXAiOiJKV1QifQ.eyJhdWQiOiJ0aW1lbGVzcy1tZXRyaWNzIiwiYXV0aF92ZXJzaW9uIjowLCJleHAiOjUwMDAwMDAwMDAsImlhdCI6MTc1NDAwMDAwMCwiaXNzIjoidGltZWxlc3MtY29uZm9ybWFuY2UiLCJqdGkiOiJjb25mb3JtYW5jZS1maXhlZC1qdGkiLCJuYmYiOjE3NTQwMDAwMDAsInNjb3BlcyI6WyJtZXRyaWNzOnJlYWQiLCJtZXRyaWNzOndyaXRlIiwibWV0cmljczpzdGF0cyIsIm1ldHJpY3M6bWFpbnRlbmFuY2UiXSwic2lnbmFsIjoibWV0cmljcyIsInN1YiI6ImNvbmZvcm1hbmNlIiwidGVuYW50IjoiZGVmYXVsdCJ9.6BxGvW6iB4_5SxdKCBPZtoc4Evkvv6pYNwUSViXtGbL3NjYbs7zI2KbSYh6vPVMTu_fsddVzs6VG1-mBgGExDQ"

  test "sign_token reproduces the committed conformance golden byte for byte" do
    seed = :binary.copy(<<7>>, 32)
    {pub, _priv} = :crypto.generate_key(:eddsa, :ed25519, seed)
    kid = pub |> binary_part(0, 8) |> Base.encode16(case: :lower)
    assert kid == "ea4a6c63e29c520a"

    claims = %{
      "iss" => "timeless-conformance",
      "aud" => "timeless-metrics",
      "sub" => "conformance",
      "jti" => "conformance-fixed-jti",
      "tenant" => "default",
      "signal" => "metrics",
      "scopes" => ["metrics:read", "metrics:write", "metrics:stats", "metrics:maintenance"],
      "auth_version" => 0,
      "iat" => 1_754_000_000,
      "nbf" => 1_754_000_000,
      "exp" => 5_000_000_000
    }

    assert TimelessUI.TelemetryAuth.sign_token(claims, kid, seed) == @golden
  end
end
