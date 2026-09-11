defmodule TimelessUIWeb.PollerLive.Requests do
  use TimelessUIWeb, :live_view

  import TimelessUIWeb.PollerNav

  alias TimelessUI.Poller.{Requests, Request}

  @impl true
  def mount(_params, _session, socket) do
    requests = Requests.list_requests()

    {:ok,
     socket
     |> assign(
       page_title: "Poller Requests",
       requests_empty?: requests == [],
       requests_count: length(requests),
       show_form: false,
       editing: nil,
       form: to_form(Requests.change_request(%Request{}))
     )
     |> stream(:requests, requests)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="poller-requests-page" class="max-w-4xl mx-auto p-8">
        <.poller_nav current={:requests} />

        <div class="flex items-center justify-between mb-8">
          <h1 class="text-2xl font-bold">Poller Requests</h1>
          <button :if={!@show_form} phx-click="show_add_form" class="btn btn-primary">
            Add Request
          </button>
        </div>

        <.request_form :if={@show_form} form={@form} editing={@editing} />

        <div :if={@requests_empty?} class="text-center text-base-content/60 py-16">
          <p class="text-lg mb-4">No requests configured</p>
          <p>Click "Add Request" to define a polling request template.</p>
        </div>

        <div class={["overflow-x-auto", @requests_empty? && "hidden"]}>
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>Name</th>
                <th>Type</th>
                <th>Tags</th>
                <th>Description</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody id="poller-requests" phx-update="stream">
              <tr :for={{id, request} <- @streams.requests} id={id}>
                <td class="font-medium">{request.name}</td>
                <td><span class="badge badge-outline">{request.type}</span></td>
                <td class="text-sm">{request.tags}</td>
                <td class="text-sm text-base-content/70">{request.description || "—"}</td>
                <td>
                  <div class="flex gap-1">
                    <button
                      phx-click="edit_request"
                      id={"edit-request-#{request.id}"}
                      phx-value-id={request.id}
                      class="btn btn-xs btn-ghost"
                    >
                      Edit
                    </button>
                    <button
                      phx-click="delete_request"
                      id={"delete-request-#{request.id}"}
                      phx-value-id={request.id}
                      data-confirm={"Delete request \"#{request.name}\"? This cannot be undone."}
                      class="btn btn-xs btn-error btn-outline"
                    >
                      Delete
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp request_form(assigns) do
    config = assigns.form[:config].value || %{}
    type = assigns.form[:type].value
    is_snmp = type in ~w(snmpget snmpwalk snmpbulkwalk)

    assigns =
      assigns
      |> Map.put(:config, config)
      |> Map.put(:is_snmp, is_snmp)
      |> Map.put(:table_name, config["table"] || "")
      |> Map.put(:community, config["community"] || "public")

    ~H"""
    <div class="card bg-base-200 mb-8">
      <div class="card-body">
        <h2 class="card-title mb-4">
          {if @editing, do: "Edit Request", else: "Add Request"}
        </h2>
        <.form for={@form} id="poller-request-form" phx-submit="save_request">
          <div class="grid grid-cols-2 gap-6 mb-6">
            <.input field={@form[:name]} type="text" label="Name" required placeholder="ifX" />
            <.input
              field={@form[:type]}
              type="select"
              label="Type"
              required
              prompt="Select type..."
              options={Request.valid_types()}
            />
          </div>
          <div class="grid grid-cols-2 gap-6 mb-6">
            <.input field={@form[:tags]} type="text" label="Tags" placeholder="ifX, snmp" />
            <.input
              field={@form[:description]}
              type="text"
              label="Description"
              placeholder="Optional description"
            />
          </div>
          <div :if={@is_snmp} class="grid grid-cols-2 gap-6 mb-6">
            <div>
              <div class="text-sm text-base-content/70 mb-2">SNMP Table</div>
              <input
                type="text"
                name="request[table]"
                value={@table_name}
                class="input input-bordered w-full"
                placeholder="ifXTable"
              />
            </div>
            <div>
              <div class="text-sm text-base-content/70 mb-2">Community</div>
              <input
                type="text"
                name="request[community]"
                value={@community}
                class="input input-bordered w-full"
                placeholder="public"
              />
            </div>
          </div>
          <div class="flex justify-end gap-2">
            <button type="button" phx-click="cancel_form" class="btn btn-ghost">Cancel</button>
            <button type="submit" class="btn btn-primary">
              {if @editing, do: "Update", else: "Create"}
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  # --- Event Handlers ---

  @impl true
  def handle_event("show_add_form", _params, socket) do
    {:noreply,
     assign(socket,
       show_form: true,
       editing: nil,
       form: to_form(Requests.change_request(%Request{}))
     )}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply, assign(socket, show_form: false, editing: nil)}
  end

  def handle_event("edit_request", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(id),
         {:ok, request} <- Requests.get_request(id) do
      {:noreply,
       assign(socket,
         show_form: true,
         editing: request,
         form: to_form(Requests.change_request(request))
       )}
    else
      _ -> {:noreply, put_flash(socket, :error, "Request no longer exists.")}
    end
  end

  def handle_event("save_request", %{"request" => params}, socket) do
    creating? = socket.assigns.editing == nil
    table = String.trim(params["table"] || "")
    community = String.trim(params["community"] || "public")

    config =
      if table != "" do
        %{"table" => table, "community" => community}
      else
        %{}
      end

    params =
      params
      |> Map.drop(["table", "community"])
      |> Map.put("config", config)

    result =
      if socket.assigns.editing do
        Requests.update_request(socket.assigns.editing, params)
      else
        Requests.create_request(params)
      end

    case result do
      {:ok, request} ->
        action = if socket.assigns.editing, do: "updated", else: "created"
        requests_count = socket.assigns.requests_count + if(creating?, do: 1, else: 0)

        {:noreply,
         socket
         |> assign(
           show_form: false,
           editing: nil,
           requests_empty?: false,
           requests_count: requests_count
         )
         |> stream_insert(:requests, request)
         |> put_flash(:info, "Request #{action}.")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(:error, "Failed to save request.")}
    end
  end

  def handle_event("delete_request", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(id),
         {:ok, request} <- Requests.get_request(id) do
      case Requests.delete_request(request) do
        {:ok, deleted} ->
          requests_count = max(socket.assigns.requests_count - 1, 0)

          {:noreply,
           socket
           |> assign(requests_empty?: requests_count == 0, requests_count: requests_count)
           |> stream_delete(:requests, deleted)
           |> put_flash(:info, "Request deleted.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete request.")}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "Request no longer exists.")}
    end
  end
end
