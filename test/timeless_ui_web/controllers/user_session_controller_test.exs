defmodule TimelessUIWeb.UserSessionControllerTest do
  use TimelessUIWeb.ConnCase

  import TimelessUI.AccountsFixtures

  setup do
    %{user: user_fixture()}
  end

  describe "POST /users/log-in" do
    test "logs the user in", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"username" => user.username, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/canvas"

      conn = get(conn, ~p"/canvas")
      response = html_response(conn, 200)
      assert response =~ user.username
      assert response =~ ~p"/users/settings"
      assert response =~ ~p"/users/log-out"
    end

    test "logs the user in with remember me", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{
            "username" => user.username,
            "password" => valid_user_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_timeless_ui_web_user_remember_me"]
      assert redirected_to(conn) == ~p"/canvas"
    end

    test "logs the user in with return to", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        conn
        |> init_test_session(user_return_to: "/foo/bar")
        |> post(~p"/users/log-in", %{
          "user" => %{
            "username" => user.username,
            "password" => valid_user_password()
          }
        })

      assert redirected_to(conn) == "/foo/bar"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
    end

    test "redirects to login page with invalid credentials", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"username" => user.username, "password" => "invalid_password"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid username or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "POST /users/update-password" do
    test "forced password change redirects to canvas, not back to settings", %{
      conn: conn,
      user: user
    } do
      user =
        user
        |> set_password()
        |> Ecto.Changeset.change(must_change_password: true)
        |> TimelessUI.Repo.update!()

      # Logging in with a pending password change lands on settings
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"username" => user.username, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == ~p"/users/settings"

      # Changing the password clears the flag and goes to canvas
      new_password = "brand new password!"

      conn =
        post(conn, ~p"/users/update-password", %{
          "user" => %{
            "username" => user.username,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      assert redirected_to(conn) == ~p"/canvas"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Password updated successfully"
      refute TimelessUI.Repo.reload!(user).must_change_password

      # Subsequent logins also go to canvas
      conn =
        build_conn()
        |> post(~p"/users/log-in", %{
          "user" => %{"username" => user.username, "password" => new_password}
        })

      assert redirected_to(conn) == ~p"/canvas"
    end
  end

  describe "DELETE /users/log-out" do
    test "logs the user out", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> delete(~p"/users/log-out")
      assert redirected_to(conn) == ~p"/canvas"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "succeeds even if the user is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/users/log-out")
      assert redirected_to(conn) == ~p"/canvas"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end
end
