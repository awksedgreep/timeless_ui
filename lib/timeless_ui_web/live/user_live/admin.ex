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
            <.form for={@form} id="create_user_form" phx-submit="create" phx-change="validate" class="space-y-4">
              <.input field={@form[:username]} type="text" label="Username" required phx-mounted={JS.focus()} />
              <.input field={@form[:password]} type="password" label="Password" required />
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
            <tbody>
              <tr :for={user <- @users} id={"user-#{user.id}"}>
                <td><%= user.username %></td>
                <td><span class={["badge", user.role == "admin" && "badge-primary"]}><%= user.role %></span></td>
                <td><%= Calendar.strftime(user.inserted_at, "%Y-%m-%d") %></td>
                <td>
                  <button
                    :if={user.id != @current_scope.user.id}
                    phx-click="delete"
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
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    changeset = Ecto.Changeset.change(%User{}, %{role: "viewer"})

    {:ok,
     socket
     |> assign(:users, Accounts.list_users())
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("create", %{"user" => user_params}, socket) do
    case Accounts.create_user(user_params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "User #{user.username} created.")
         |> assign(:users, Accounts.list_users())
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

  def handle_event("delete", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)
    {:ok, _} = Accounts.delete_user(user)

    {:noreply,
     socket
     |> put_flash(:info, "User #{user.username} deleted.")
     |> assign(:users, Accounts.list_users())}
  end

  defp assign_form(socket, changeset) do
    assign(socket, :form, to_form(changeset, as: "user"))
  end
end
