defmodule TimelessUIWeb.TelemetryAdminControllerTest do
  use TimelessUIWeb.ConnCase, async: false

  import TimelessUI.AccountsFixtures

  test "admin manages public policy and short-lived tokens through the session boundary", %{
    conn: conn
  } do
    admin = user_fixture(%{role: "admin"})
    conn = log_in_user(conn, admin)

    status = conn |> get(~p"/admin/api/telemetry/data-planes") |> json_response(200)
    assert status["metrics"]["process_phase"] == "stopped"
    assert status["logs"]["process_ready"] == false
    refute inspect(status) =~ "Bearer "

    key =
      conn
      |> post(~p"/admin/api/telemetry/auth/keys/rotate", %{"kid" => "api-key"})
      |> json_response(200)

    assert key == %{
             "expires_at" => key["expires_at"],
             "kid" => "api-key",
             "state" => "active"
           }

    policy =
      conn
      |> put(~p"/admin/api/telemetry/auth/policies/metrics/default/collector-api", %{
        "scopes" => ["metrics:read"],
        "limits" => %{"max_query_rows" => 25}
      })
      |> json_response(200)

    assert policy["subject"] == "collector-api"
    assert policy["scopes"] == ["metrics:read"]
    assert policy["limits"]["max_query_rows"] == 25

    issued =
      conn
      |> post(~p"/admin/api/telemetry/auth/tokens/metrics/collector-api", %{
        "expires_in" => 60,
        "scopes" => ["metrics:read"],
        "limits" => %{"max_query_rows" => 10}
      })
      |> json_response(200)

    assert length(String.split(issued["token"], ".")) == 3
    assert issued["kid"] == "api-key"

    revoked =
      conn
      |> post(~p"/admin/api/telemetry/auth/tokens/revoke", %{
        "token" => issued["token"],
        "reason" => "test"
      })
      |> json_response(200)

    assert revoked["jti"] == issued["jti"]
  end

  test "viewer cannot reach telemetry administration APIs", %{conn: conn} do
    viewer = user_fixture(%{role: "viewer"})

    conn = conn |> log_in_user(viewer) |> get(~p"/admin/api/telemetry/data-planes")
    assert redirected_to(conn) == ~p"/canvas"
  end

  test "invalid policy input returns a stable non-secret error", %{conn: conn} do
    admin = user_fixture(%{role: "admin"})

    response =
      conn
      |> log_in_user(admin)
      |> put(~p"/admin/api/telemetry/auth/policies/logs/default/collector", %{
        "scopes" => []
      })
      |> json_response(422)

    assert response["error"] == "telemetry_control_plane"
    assert response["reason"] == "invalid_configuration"
    refute inspect(response) =~ "token"
  end
end
