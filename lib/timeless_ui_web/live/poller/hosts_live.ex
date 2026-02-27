defmodule TimelessUIWeb.PollerLive.Hosts do
  use TimelessUIWeb, :live_view

  alias TimelessUI.Poller.{Hosts, Host}

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
              <th>Groups</th>
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
                <td class="text-sm">{format_groups(host.groups)}</td>
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
        <form phx-submit="save_host">
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div class="form-control">
              <label class="label"><span class="label-text">Name *</span></label>
              <input
                type="text"
                name="host[name]"
                value={Ecto.Changeset.get_field(@changeset, :name)}
                required
                class="input input-bordered"
                placeholder="e.g. core-router-1"
              />
            </div>
            <div class="form-control">
              <label class="label"><span class="label-text">IP Address *</span></label>
              <input
                type="text"
                name="host[ip]"
                value={Ecto.Changeset.get_field(@changeset, :ip)}
                required
                class="input input-bordered"
                placeholder="e.g. 192.168.1.1"
              />
            </div>
            <div class="form-control">
              <label class="label"><span class="label-text">Type</span></label>
              <input
                type="text"
                name="host[type]"
                value={Ecto.Changeset.get_field(@changeset, :type)}
                class="input input-bordered"
                placeholder="e.g. router, switch, server"
              />
            </div>
            <div class="form-control">
              <label class="label"><span class="label-text">Status</span></label>
              <select name="host[status]" class="select select-bordered">
                <option
                  value="active"
                  selected={Ecto.Changeset.get_field(@changeset, :status) == "active"}
                >
                  Active
                </option>
                <option
                  value="inactive"
                  selected={Ecto.Changeset.get_field(@changeset, :status) == "inactive"}
                >
                  Inactive
                </option>
              </select>
            </div>
            <div class="form-control sm:col-span-2">
              <label class="label"><span class="label-text">Groups (JSON)</span></label>
              <textarea
                name="host[groups]"
                class="textarea textarea-bordered font-mono text-sm"
                rows="2"
                placeholder={~s|{"region": "us-east", "role": "router"}|}
              >{encode_json(Ecto.Changeset.get_field(@changeset, :groups))}</textarea>
            </div>
            <div class="form-control sm:col-span-2">
              <label class="label"><span class="label-text">Tags (JSON array)</span></label>
              <textarea
                name="host[tags]"
                class="textarea textarea-bordered font-mono text-sm"
                rows="2"
                placeholder={~s|["production", "critical"]|}
              >{Ecto.Changeset.get_field(@changeset, :tags) || "[]"}</textarea>
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
    params = parse_json_fields(params, ["groups"])

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
