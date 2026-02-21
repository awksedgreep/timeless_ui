defmodule TimelessUIWeb.CanvasListLive do
  use TimelessUIWeb, :live_view

  alias TimelessUI.Canvases
  alias TimelessUI.Canvases.Policy

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_scope.user
    canvases = Canvases.list_accessible_canvases(current_user)

    {:ok,
     assign(socket,
       canvases: canvases,
       current_user: current_user,
       is_admin: Policy.admin?(current_user),
       page_title: "My Canvases"
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-8">
      <div class="flex items-center justify-between mb-8">
        <h1 class="text-2xl font-bold">
          My Canvases <span :if={@is_admin} class="badge badge-primary ml-2">Admin</span>
        </h1>
        <button phx-click="new_canvas" class="btn btn-primary">
          New Canvas
        </button>
      </div>

      <div :if={@canvases == []} class="text-center text-base-content/60 py-16">
        <p class="text-lg mb-4">No canvases yet</p>
        <p>Click "New Canvas" to create your first canvas.</p>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
        <div :for={canvas <- @canvases} class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <h2 class="card-title">
              <.link navigate={~p"/canvas/#{canvas.id}"} class="hover:underline">
                {canvas.name}
              </.link>
            </h2>
            <p class="text-sm text-base-content/60">
              Updated {Calendar.strftime(canvas.updated_at, "%b %d, %Y %H:%M")}
            </p>
            <div class="card-actions justify-end mt-2">
              <.link navigate={~p"/canvas/#{canvas.id}"} class="btn btn-sm btn-primary">
                Open
              </.link>
              <button
                :if={canvas.user_id == @current_user.id}
                phx-click="delete_canvas"
                phx-value-id={canvas.id}
                data-confirm="Delete this canvas? This cannot be undone."
                class="btn btn-sm btn-error btn-outline"
              >
                Delete
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("new_canvas", _params, socket) do
    user = socket.assigns.current_user
    name = "Canvas #{DateTime.to_unix(DateTime.utc_now())}"

    case Canvases.create_canvas(user.id, name) do
      {:ok, canvas} ->
        {:noreply, redirect(socket, to: ~p"/canvas/#{canvas.id}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not create canvas")}
    end
  end

  def handle_event("delete_canvas", %{"id" => id_str}, socket) do
    user = socket.assigns.current_user
    {id, ""} = Integer.parse(id_str)

    case Canvases.delete_canvas(id, user.id) do
      {:ok, _} ->
        canvases = Canvases.list_accessible_canvases(user)
        {:noreply, assign(socket, canvases: canvases)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not delete canvas")}
    end
  end
end
