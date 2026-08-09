defmodule TimelessUIWeb.TelemetryAdminController do
  use TimelessUIWeb, :controller

  alias TimelessUI.TelemetryAuth
  alias TimelessUI.TelemetryDataPlane

  def status(conn, _params) do
    respond(conn, TelemetryDataPlane.status(conn.assigns.current_scope))
  end

  def retry(conn, %{"signal" => signal}) do
    respond(conn, TelemetryDataPlane.retry(conn.assigns.current_scope, signal))
  end

  def rotate_key(conn, params) do
    opts =
      case params["kid"] do
        kid when is_binary(kid) and kid != "" -> [kid: kid]
        _ -> []
      end

    with {:ok, key} <- TelemetryAuth.rotate_key(conn.assigns.current_scope, opts),
         :ok <- TelemetryDataPlane.refresh_authorization() do
      json(conn, %{kid: key.kid, state: key.state, expires_at: key.expires_at})
    else
      error -> error_response(conn, error)
    end
  end

  def revoke_key(conn, %{"kid" => kid}) do
    with {:ok, key} <- TelemetryAuth.revoke_key(conn.assigns.current_scope, kid),
         :ok <- TelemetryDataPlane.refresh_authorization() do
      json(conn, %{kid: key.kid, state: key.state})
    else
      error -> error_response(conn, error)
    end
  end

  def put_policy(conn, %{"signal" => signal, "tenant" => tenant, "subject" => subject} = params) do
    attrs = %{
      signal: signal,
      tenant: tenant,
      subject: subject,
      scopes: params["scopes"],
      limits: params["limits"] || %{},
      enabled: Map.get(params, "enabled", true)
    }

    with {:ok, policy} <- TelemetryAuth.put_policy(conn.assigns.current_scope, attrs),
         :ok <- TelemetryDataPlane.refresh_authorization() do
      json(conn, policy_response(policy))
    else
      error -> error_response(conn, error)
    end
  end

  def bump_auth_version(conn, %{
        "signal" => signal,
        "tenant" => tenant,
        "subject" => subject
      }) do
    with {:ok, policy} <-
           TelemetryAuth.bump_auth_version(
             conn.assigns.current_scope,
             subject,
             tenant,
             signal
           ),
         :ok <- TelemetryDataPlane.refresh_authorization() do
      json(conn, policy_response(policy))
    else
      error -> error_response(conn, error)
    end
  end

  def issue_token(conn, %{"signal" => signal, "subject" => subject} = params) do
    opts =
      []
      |> optional(:tenant, params["tenant"])
      |> optional(:scopes, params["scopes"])
      |> optional(:limits, params["limits"])
      |> optional(:expires_in, params["expires_in"])

    case TelemetryAuth.issue_token(conn.assigns.current_scope, subject, signal, opts) do
      {:ok, issued} ->
        json(conn, %{
          token: issued.token,
          kid: issued.kid,
          expires_at: issued.claims["exp"],
          jti: issued.claims["jti"]
        })

      error ->
        error_response(conn, error)
    end
  end

  def revoke_token(conn, %{"token" => token} = params) do
    with {:ok, revocation} <-
           TelemetryAuth.revoke_token(conn.assigns.current_scope, token, params["reason"]),
         :ok <- TelemetryDataPlane.refresh_authorization() do
      json(conn, %{jti: revocation.jti, expires_at: revocation.expires_at})
    else
      error -> error_response(conn, error)
    end
  end

  defp respond(conn, {:ok, result}), do: json(conn, json_safe(result))
  defp respond(conn, error), do: error_response(conn, error)

  defp error_response(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "telemetry_control_plane",
      reason: "invalid_configuration",
      details: errors(changeset)
    })
  end

  defp error_response(conn, {:error, reason}) do
    status = if reason in [:forbidden], do: :forbidden, else: :unprocessable_entity

    conn
    |> put_status(status)
    |> json(%{error: "telemetry_control_plane", reason: reason_text(reason)})
  end

  defp error_response(conn, reason), do: error_response(conn, {:error, reason})

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, rendered ->
        String.replace(rendered, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp policy_response(policy) do
    %{
      subject: policy.subject,
      tenant: policy.tenant,
      signal: policy.signal,
      scopes: policy.scopes["values"],
      limits: policy.limits,
      auth_version: policy.auth_version,
      enabled: policy.enabled
    }
  end

  defp optional(opts, _key, nil), do: opts
  defp optional(opts, key, value), do: Keyword.put(opts, key, value)

  defp json_safe(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, json_safe(item)} end)

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)

  defp json_safe(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&json_safe/1)

  defp json_safe(value), do: value

  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason, limit: 20, printable_limit: 200)
end
