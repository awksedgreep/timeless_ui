defmodule TimelessUIWeb.UserLive.LoginTest do
  use TimelessUIWeb.ConnCase

  import Phoenix.LiveViewTest
  import TimelessUI.AccountsFixtures

  describe "login page" do
    test "renders login page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Log in"
      assert html =~ "Username"
      assert html =~ "Password"
    end
  end

  describe "user login" do
    test "redirects if user logs in with valid credentials", %{conn: conn} do
      user = user_fixture() |> set_password()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form",
          user: %{username: user.username, password: valid_user_password(), remember_me: true}
        )

      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/users/settings"
    end

    test "redirects to login page with a flash error if credentials are invalid", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form = form(lv, "#login_form", user: %{username: "test-user", password: "123456"})

      render_submit(form)

      conn = follow_trigger_action(form, conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid username or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      user = user_fixture()
      %{user: user, conn: log_in_user(conn, user)}
    end

    test "shows login page with username filled in", %{conn: conn, user: user} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "You need to reauthenticate"
      assert html =~ ~s(name="user[username]")
      assert html =~ ~s(value="#{user.username}")
    end
  end
end
