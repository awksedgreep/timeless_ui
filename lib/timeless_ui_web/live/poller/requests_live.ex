defmodule TimelessUIWeb.PollerLive.Requests do
  use TimelessUIWeb, :live_view

  alias TimelessUI.Poller.{Requests, Request}
  alias Ecto.Changeset

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Poller Requests",
       requests: Requests.list_requests(),
       show_form: false,
       editing: nil,
       changeset: Requests.change_request(%Request{})
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-8">
      <div class="flex items-center justify-between mb-8">
        <div class="flex items-center gap-4">
          <.link navigate={~p"/poller"} class="btn btn-sm btn-ghost">&larr; Dashboard</.link>
          <h1 class="text-2xl font-bold">Poller Requests</h1>
        </div>
        <button :if={!@show_form} phx-click="show_add_form" class="btn btn-primary">
          Add Request
        </button>
      </div>

      <.request_form :if={@show_form} changeset={@changeset} editing={@editing} />

      <div :if={@requests == []} class="text-center text-base-content/60 py-16">
        <p class="text-lg mb-4">No requests configured</p>
        <p>Click "Add Request" to define a polling request template.</p>
      </div>

      <div :if={@requests != []} class="overflow-x-auto">
        <table class="table table-zebra">
          <thead>
            <tr>
              <th>Name</th>
              <th>Type</th>
              <th>Description</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= for request <- @requests do %>
              <tr>
                <td class="font-medium">{request.name}</td>
                <td><span class="badge badge-outline">{request.type}</span></td>
                <td class="text-sm text-base-content/70">{request.description || "—"}</td>
                <td>
                  <div class="flex gap-1">
                    <button
                      phx-click="edit_request"
                      phx-value-id={request.id}
                      class="btn btn-xs btn-ghost"
                    >
                      Edit
                    </button>
                    <button
                      phx-click="delete_request"
                      phx-value-id={request.id}
                      data-confirm={"Delete request \"#{request.name}\"? This cannot be undone."}
                      class="btn btn-xs btn-error btn-outline"
                    >
                      Delete
                    </button>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp request_form(assigns) do
    ~H"""
    <div class="card bg-base-200 mb-8">
      <div class="card-body">
        <h2 class="card-title mb-4">
          {if @editing, do: "Edit Request", else: "Add Request"}
        </h2>
        <form phx-submit="save_request">
          <div class="grid grid-cols-2 gap-6 mb-6">
            <div>
              <div class="text-sm text-base-content/70 mb-2">Name *</div>
              <input
                type="text"
                name="request[name]"
                value={Changeset.get_field(@changeset, :name)}
                required
                class="input input-bordered w-full"
                placeholder="ifX"
              />
            </div>
            <div>
              <div class="text-sm text-base-content/70 mb-2">Type *</div>
              <select name="request[type]" class="select select-bordered w-full" required>
                <option value="">Select type...</option>
                <%= for type <- Request.valid_types() do %>
                  <option value={type} selected={Changeset.get_field(@changeset, :type) == type}>
                    {type}
                  </option>
                <% end %>
              </select>
            </div>
          </div>
          <div class="mb-6">
            <div class="text-sm text-base-content/70 mb-2">Description</div>
            <input
              type="text"
              name="request[description]"
              value={Changeset.get_field(@changeset, :description)}
              class="input input-bordered w-full"
              placeholder="Optional description"
            />
          </div>
          <div class="mb-6">
            <div class="text-sm text-base-content/70 mb-2">OIDs (one per line)</div>
            <textarea
              name="request[oids]"
              class="textarea textarea-bordered font-mono text-sm w-full"
              rows="4"
              placeholder=".1.3.6.1.2.1.31.1.1\n.1.3.6.1.2.1.2.2.1"
            >{oids_from_config(Changeset.get_field(@changeset, :config))}</textarea>
          </div>
          <div class="flex justify-end gap-2">
            <button type="button" phx-click="cancel_form" class="btn btn-ghost">Cancel</button>
            <button type="submit" class="btn btn-primary">
              {if @editing, do: "Update", else: "Create"}
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  defp oids_from_config(nil), do: ""
  defp oids_from_config(config) when config == %{}, do: ""

  defp oids_from_config(config) do
    oids = Map.get(config, "oids") || Map.get(config, :oids) || []
    Enum.join(oids, "\n")
  end

  # --- Event Handlers ---

  @impl true
  def handle_event("show_add_form", _params, socket) do
    {:noreply,
     assign(socket,
       show_form: true,
       editing: nil,
       changeset: Requests.change_request(%Request{})
     )}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply, assign(socket, show_form: false, editing: nil)}
  end

  def handle_event("edit_request", %{"id" => id}, socket) do
    request = Requests.get_request!(id)

    {:noreply,
     assign(socket,
       show_form: true,
       editing: request,
       changeset: Requests.change_request(request)
     )}
  end

  def handle_event("save_request", %{"request" => params}, socket) do
    oids =
      (params["oids"] || "")
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    params =
      params
      |> Map.delete("oids")
      |> Map.put("config", %{"oids" => oids})

    result =
      if socket.assigns.editing do
        Requests.update_request(socket.assigns.editing, params)
      else
        Requests.create_request(params)
      end

    case result do
      {:ok, _request} ->
        action = if socket.assigns.editing, do: "updated", else: "created"

        {:noreply,
         socket
         |> assign(show_form: false, editing: nil, requests: Requests.list_requests())
         |> put_flash(:info, "Request #{action}.")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(changeset: changeset)
         |> put_flash(:error, "Failed to save request.")}
    end
  end

  def handle_event("delete_request", %{"id" => id}, socket) do
    request = Requests.get_request!(id)

    case Requests.delete_request(request) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(requests: Requests.list_requests())
         |> put_flash(:info, "Request deleted.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete request.")}
    end
  end
end
