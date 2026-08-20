defmodule TimelessUIWeb.UserSessionController do
  use TimelessUIWeb, :controller

  require Logger

  alias TimelessUI.Accounts
  alias TimelessUI.Accounts.LoginThrottle
  alias TimelessUIWeb.ClientIP
  alias TimelessUIWeb.UserAuth

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  defp create(conn, %{"user" => user_params}, info) do
    %{"username" => username, "password" => password} = user_params
    source = ClientIP.resolve(conn)

    cond do
      LoginThrottle.locked?(source) ->
        # Deliberately does not verify the password: a locked source gets the
        # same answer whether or not the credentials were correct.
        Logger.warning(
          "[login] blocked locked source ip=#{source} username=#{inspect(safe(username))}"
        )

        deny(conn, username)

      user = Accounts.get_user_by_username_and_password(username, password) ->
        LoginThrottle.clear(source)

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      true ->
        case LoginThrottle.record_failure(source) do
          {:locked, seconds} ->
            Logger.warning(
              "[login] failure ip=#{source} username=#{inspect(safe(username))}" <>
                " - threshold reached, locked for #{seconds}s"
            )

          :ok ->
            Logger.warning("[login] failure ip=#{source} username=#{inspect(safe(username))}")
        end

        deny(conn, username)
    end
  end

  # One response for both "wrong password" and "locked out". Distinguishing them
  # would confirm that a username exists, undoing the constant-time handling of
  # unknown users in Accounts.
  defp deny(conn, username) do
    conn
    |> put_flash(:error, "Invalid username or password")
    |> put_flash(:username, String.slice(username, 0, 160))
    |> redirect(to: ~p"/users/log-in")
  end

  # The username is attacker-controlled and ends up in a log line. Bound its
  # length, and let inspect/1 escape newlines so it cannot forge log entries.
  defp safe(username), do: String.slice(username, 0, 64)

  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)
    {:ok, {_user, expired_tokens}} = Accounts.update_user_password(user, user_params)

    UserAuth.disconnect_sessions(expired_tokens)

    conn
    |> delete_session(:user_return_to)
    |> create(params, "Password updated successfully.")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
