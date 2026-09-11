defmodule TimelessUIWeb.UserLive.Admin do
  use TimelessUIWeb, :live_view

  alias TimelessUI.Accounts
  alias TimelessUI.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-2xl space-y-8">
        <.header>
          User Management
          <:subtitle>Create and manage users</:subtitle>
        </.header>

        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title">Create User</h2>
            <.form
              for={@form}
              id="create_user_form"
              phx-submit="create"
              phx-change="validate"
              class="space-y-4"
            >
              <.input
                field={@form[:username]}
                type="text"
                label="Username"
                required
                phx-debounce="300"
                phx-mounted={JS.focus()}
              />
              <.input
                field={@form[:password]}
                type="password"
                label="Password"
                required
                phx-debounce="300"
              />
              <.input
                field={@form[:role]}
                type="select"
                label="Role"
                options={[{"Admin", "admin"}, {"Viewer", "viewer"}]}
              />
              <.button class="btn btn-primary">Create User</.button>
            </.form>
          </div>
        </div>

        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>Username</th>
                <th>Role</th>
                <th>Created</th>
                <th></th>
              </tr>
            </thead>
            <tbody id="admin-users" phx-update="stream">
              <tr :for={{id, user} <- @streams.users} id={id}>
                <td>{user.username}</td>
                <td>
                  <span class={["badge", user.role == "admin" && "badge-primary"]}>{user.role}</span>
                </td>
                <td>{Calendar.strftime(user.inserted_at, "%Y-%m-%d")}</td>
                <td class="flex gap-2">
                  <button
                    phx-click="show_reset"
                    id={"reset-user-#{user.id}"}
                    phx-value-id={user.id}
                    class="btn btn-warning btn-xs"
                  >
                    Reset Password
                  </button>
                  <button
                    :if={user.id != @current_scope.user.id}
                    phx-click="delete"
                    id={"delete-user-#{user.id}"}
                    phx-value-id={user.id}
                    data-confirm={"Delete #{user.username}?"}
                    class="btn btn-error btn-xs"
                  >
                    Delete
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={@reset_user} class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title">Reset password for {@reset_user.username}</h2>
            <.form for={to_form(%{}, as: "reset")} id="reset-form" phx-submit="reset_password">
              <input type="hidden" name="reset[user_id]" value={@reset_user.id} />
              <.input name="reset[password]" type="password" label="New password" required value="" />
              <div class="flex gap-2 mt-4">
                <.button class="btn btn-primary">Reset Password</.button>
                <button type="button" phx-click="cancel_reset" class="btn">Cancel</button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    changeset = Ecto.Changeset.change(%User{}, %{role: "viewer"})
    users = Accounts.list_users()

    {:ok,
     socket
     |> assign(:reset_user, nil)
     |> assign_form(changeset)
     |> stream(:users, users)}
  end

  @impl true
  def handle_event("create", %{"user" => user_params}, socket) do
    case Accounts.create_user(user_params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "User #{user.username} created.")
         |> stream_insert(:users, user)
         |> assign_form(Ecto.Changeset.change(%User{}, %{role: "viewer"}))}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset =
      %User{}
      |> User.registration_changeset(user_params, hash_password: false)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("show_reset", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(id),
         {:ok, user} <- Accounts.get_user(id) do
      {:noreply, assign(socket, :reset_user, user)}
    else
      _ -> {:noreply, put_flash(socket, :error, "User no longer exists.")}
    end
  end

  def handle_event("cancel_reset", _params, socket) do
    {:noreply, assign(socket, :reset_user, nil)}
  end

  def handle_event(
        "reset_password",
        %{"reset" => %{"user_id" => id, "password" => password}},
        socket
      ) do
    with {id, ""} <- Integer.parse(id),
         {:ok, user} <- Accounts.get_user(id) do
      case Accounts.reset_user_password(user, password) do
        {:ok, _user} ->
          {:noreply,
           socket
           |> put_flash(:info, "Password reset for #{user.username}.")
           |> assign(:reset_user, nil)}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to reset password.")}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "User no longer exists.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(id),
         false <- id == socket.assigns.current_scope.user.id,
         {:ok, user} <- Accounts.get_user(id),
         {:ok, deleted} <- Accounts.delete_user(user) do
      {:noreply,
       socket
       |> put_flash(:info, "User #{user.username} deleted.")
       |> stream_delete(:users, deleted)}
    else
      _ -> {:noreply, put_flash(socket, :error, "User no longer exists.")}
    end
  end

  defp assign_form(socket, changeset) do
    assign(socket, :form, to_form(changeset, as: "user"))
  end
end
