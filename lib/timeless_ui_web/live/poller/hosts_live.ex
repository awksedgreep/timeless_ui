defmodule TimelessUIWeb.PollerLive.Hosts do
  use TimelessUIWeb, :live_view

  alias TimelessUI.Poller.{Hosts, Host}
  alias Ecto.Changeset

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Poller Hosts",
       hosts: Hosts.list_hosts(),
       show_form: false,
       editing: nil,
       changeset: Hosts.change_host(%Host{})
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-8">
      <div class="flex items-center justify-between mb-8">
        <div class="flex items-center gap-4">
          <.link navigate={~p"/poller"} class="btn btn-sm btn-ghost">&larr; Dashboard</.link>
          <h1 class="text-2xl font-bold">Poller Hosts</h1>
        </div>
        <button :if={!@show_form} phx-click="show_add_form" class="btn btn-primary">
          Add Host
        </button>
      </div>

      <.host_form :if={@show_form} changeset={@changeset} editing={@editing} />

      <div :if={@hosts == []} class="text-center text-base-content/60 py-16">
        <p class="text-lg mb-4">No hosts configured</p>
        <p>Click "Add Host" to add a network device to poll.</p>
      </div>

      <div :if={@hosts != []} class="overflow-x-auto">
        <table class="table table-zebra">
          <thead>
            <tr>
              <th>Name</th>
              <th>IP</th>
              <th>Type</th>
              <th>Status</th>
              <th>Tags</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= for host <- @hosts do %>
              <tr>
                <td class="font-medium">{host.name}</td>
                <td class="font-mono text-sm">{host.ip}</td>
                <td>{host.type}</td>
                <td><.status_badge status={host.status} /></td>
                <td class="text-sm">{host.tags}</td>
                <td>
                  <div class="flex gap-1">
                    <button phx-click="edit_host" phx-value-id={host.id} class="btn btn-xs btn-ghost">
                      Edit
                    </button>
                    <button
                      phx-click="delete_host"
                      phx-value-id={host.id}
                      data-confirm={"Delete host \"#{host.name}\"? This cannot be undone."}
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

  defp host_form(assigns) do
    ~H"""
    <div class="card bg-base-200 mb-8">
      <div class="card-body">
        <h2 class="card-title mb-4">
          {if @editing, do: "Edit Host", else: "Add Host"}
        </h2>
        <form phx-submit="save_host" class="space-y-4">
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-4">
            <div>
              <div class="text-sm text-base-content/70 mb-1.5">Name *</div>
              <input
                type="text"
                name="host[name]"
                value={Changeset.get_field(@changeset, :name)}
                required
                class="input input-bordered w-full"
                placeholder="core-router-1"
              />
            </div>
            <div>
              <div class="text-sm text-base-content/70 mb-1.5">IP Address *</div>
              <input
                type="text"
                name="host[ip]"
                value={Changeset.get_field(@changeset, :ip)}
                required
                class="input input-bordered w-full"
                placeholder="192.168.1.1"
              />
            </div>
            <div>
              <div class="text-sm text-base-content/70 mb-1.5">Type</div>
              <select name="host[type]" class="select select-bordered w-full">
                <option value="generic" selected={Changeset.get_field(@changeset, :type) == "generic"}>
                  Generic
                </option>
                <option value="router" selected={Changeset.get_field(@changeset, :type) == "router"}>
                  Router
                </option>
                <option value="switch" selected={Changeset.get_field(@changeset, :type) == "switch"}>
                  Switch
                </option>
                <option value="server" selected={Changeset.get_field(@changeset, :type) == "server"}>
                  Server
                </option>
                <option
                  value="firewall"
                  selected={Changeset.get_field(@changeset, :type) == "firewall"}
                >
                  Firewall
                </option>
              </select>
            </div>
            <div>
              <div class="text-sm text-base-content/70 mb-1.5">Status</div>
              <select name="host[status]" class="select select-bordered w-full">
                <option value="active" selected={Changeset.get_field(@changeset, :status) == "active"}>
                  Active
                </option>
                <option
                  value="inactive"
                  selected={Changeset.get_field(@changeset, :status) == "inactive"}
                >
                  Inactive
                </option>
              </select>
            </div>
          </div>
          <div>
            <div class="text-sm text-base-content/70 mb-1.5">Tags</div>
            <input
              type="text"
              name="host[tags]"
              value={Changeset.get_field(@changeset, :tags) || ""}
              class="input input-bordered w-full"
              placeholder="production, critical, us-east"
            />
          </div>
          <div class="flex justify-end gap-2 pt-2">
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

  defp status_badge(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5">
      <span class={["w-2.5 h-2.5 rounded-full", status_color(@status)]}></span>
      <span class="text-sm">{@status}</span>
    </div>
    """
  end

  defp status_color("active"), do: "bg-success"
  defp status_color("inactive"), do: "bg-base-content/30"
  defp status_color(_), do: "bg-warning"

  # --- Event Handlers ---

  @impl true
  def handle_event("show_add_form", _params, socket) do
    {:noreply,
     assign(socket,
       show_form: true,
       editing: nil,
       changeset: Hosts.change_host(%Host{})
     )}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply, assign(socket, show_form: false, editing: nil)}
  end

  def handle_event("edit_host", %{"id" => id}, socket) do
    host = Hosts.get_host!(id)

    {:noreply,
     assign(socket,
       show_form: true,
       editing: host,
       changeset: Hosts.change_host(host)
     )}
  end

  def handle_event("save_host", %{"host" => params}, socket) do
    result =
      if socket.assigns.editing do
        Hosts.update_host(socket.assigns.editing, params)
      else
        Hosts.create_host(params)
      end

    case result do
      {:ok, _host} ->
        action = if socket.assigns.editing, do: "updated", else: "created"

        {:noreply,
         socket
         |> assign(show_form: false, editing: nil, hosts: Hosts.list_hosts())
         |> put_flash(:info, "Host #{action}.")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(changeset: changeset)
         |> put_flash(:error, "Failed to save host.")}
    end
  end

  def handle_event("delete_host", %{"id" => id}, socket) do
    host = Hosts.get_host!(id)

    case Hosts.delete_host(host) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(hosts: Hosts.list_hosts())
         |> put_flash(:info, "Host deleted.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete host.")}
    end
  end
end
