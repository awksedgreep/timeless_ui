defmodule TimelessUIWeb.PollerLive.Requests do
  use TimelessUIWeb, :live_view

  alias TimelessUI.Poller.{Requests, Request}

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
              <th>Groups</th>
              <th>Description</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= for request <- @requests do %>
              <tr>
                <td class="font-medium">{request.name}</td>
                <td><span class="badge badge-outline">{request.type}</span></td>
                <td class="text-sm">{format_groups(request.groups)}</td>
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
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div class="form-control">
              <label class="label"><span class="label-text">Name *</span></label>
              <input
                type="text"
                name="request[name]"
                value={Ecto.Changeset.get_field(@changeset, :name)}
                required
                class="input input-bordered"
                placeholder="e.g. ping-all"
              />
            </div>
            <div class="form-control">
              <label class="label"><span class="label-text">Type *</span></label>
              <select name="request[type]" class="select select-bordered" required>
                <option value="">Select type...</option>
                <%= for type <- TimelessUI.Poller.Request.valid_types() do %>
                  <option
                    value={type}
                    selected={Ecto.Changeset.get_field(@changeset, :type) == type}
                  >
                    {type}
                  </option>
                <% end %>
              </select>
            </div>
            <div class="form-control sm:col-span-2">
              <label class="label"><span class="label-text">Description</span></label>
              <input
                type="text"
                name="request[description]"
                value={Ecto.Changeset.get_field(@changeset, :description)}
                class="input input-bordered"
                placeholder="Optional description"
              />
            </div>
            <div class="form-control sm:col-span-2">
              <label class="label"><span class="label-text">Groups (JSON)</span></label>
              <textarea
                name="request[groups]"
                class="textarea textarea-bordered font-mono text-sm"
                rows="2"
                placeholder={~s|{"role": "router"}|}
              >{encode_json(Ecto.Changeset.get_field(@changeset, :groups))}</textarea>
            </div>
            <div class="form-control sm:col-span-2">
              <label class="label"><span class="label-text">Config (JSON)</span></label>
              <textarea
                name="request[config]"
                class="textarea textarea-bordered font-mono text-sm"
                rows="4"
                placeholder={~s|{"oids": [".1.3.6.1.2.1.1.3.0"]}|}
              >{encode_json(Ecto.Changeset.get_field(@changeset, :config))}</textarea>
            </div>
          </div>
          <div class="card-actions justify-end mt-6">
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

  defp format_groups(nil), do: ""
  defp format_groups(groups) when groups == %{}, do: ""

  defp format_groups(groups) do
    groups
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
    |> Enum.join(", ")
  end

  defp encode_json(nil), do: ""
  defp encode_json(val) when val == %{}, do: ""
  defp encode_json(val), do: Jason.encode!(val, pretty: true)

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
    params = parse_json_fields(params, ["groups", "config"])

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

  defp parse_json_fields(params, fields) do
    Enum.reduce(fields, params, fn field, acc ->
      case Map.get(acc, field) do
        nil ->
          acc

        "" ->
          Map.put(acc, field, %{})

        str when is_binary(str) ->
          case Jason.decode(str) do
            {:ok, val} -> Map.put(acc, field, val)
            {:error, _} -> acc
          end

        _ ->
          acc
      end
    end)
  end
end
