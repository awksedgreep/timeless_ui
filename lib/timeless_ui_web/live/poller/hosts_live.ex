defmodule TimelessUIWeb.PollerLive.Hosts do
  use TimelessUIWeb, :live_view

  import TimelessUIWeb.PollerNav

  alias TimelessUI.Poller.{Hosts, Host}

  @impl true
  def mount(_params, _session, socket) do
    hosts = Hosts.list_hosts()

    {:ok,
     socket
     |> assign(
       page_title: "Poller Hosts",
       hosts_empty?: hosts == [],
       hosts_count: length(hosts),
       show_form: false,
       editing: nil,
       form: to_form(Hosts.change_host(%Host{}))
     )
     |> stream(:hosts, hosts)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="poller-hosts-page" class="max-w-4xl mx-auto p-8">
        <.poller_nav current={:hosts} />

        <div class="flex items-center justify-between mb-8">
          <h1 class="text-2xl font-bold">Poller Hosts</h1>
          <button :if={!@show_form} phx-click="show_add_form" class="btn btn-primary">
            Add Host
          </button>
        </div>

        <.host_form :if={@show_form} form={@form} editing={@editing} />

        <div :if={@hosts_empty?} class="text-center text-base-content/60 py-16">
          <p class="text-lg mb-4">No hosts configured</p>
          <p>Click "Add Host" to add a network device to poll.</p>
        </div>

        <div class={["overflow-x-auto", @hosts_empty? && "hidden"]}>
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>Name</th>
                <th>IP</th>
                <th>Status</th>
                <th>Tags</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody id="poller-hosts" phx-update="stream">
              <tr :for={{id, host} <- @streams.hosts} id={id}>
                <td class="font-medium">{host.name}</td>
                <td class="font-mono text-sm">{host.ip}</td>
                <td><.status_badge status={host.status} /></td>
                <td class="text-sm">{host.tags}</td>
                <td>
                  <div class="flex gap-1">
                    <button
                      id={"edit-host-#{host.id}"}
                      phx-click="edit_host"
                      phx-value-id={host.id}
                      class="btn btn-xs btn-ghost"
                    >
                      Edit
                    </button>
                    <button
                      phx-click="delete_host"
                      id={"delete-host-#{host.id}"}
                      phx-value-id={host.id}
                      data-confirm={"Delete host \"#{host.name}\"? This cannot be undone."}
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

  defp host_form(assigns) do
    ~H"""
    <div class="card bg-base-200 mb-8">
      <div class="card-body">
        <h2 class="card-title mb-4">
          {if @editing, do: "Edit Host", else: "Add Host"}
        </h2>
        <.form for={@form} id="poller-host-form" phx-submit="save_host">
          <div class="grid grid-cols-2 gap-6 mb-6">
            <.input
              field={@form[:name]}
              type="text"
              label="Name"
              required
              placeholder="core-router-1"
            />
            <.input
              field={@form[:ip]}
              type="text"
              label="IP Address"
              required
              placeholder="192.168.1.1"
            />
          </div>
          <.input
            field={@form[:tags]}
            type="text"
            label="Tags"
            placeholder="production, critical, us-east"
          />
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
       form: to_form(Hosts.change_host(%Host{}))
     )}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply, assign(socket, show_form: false, editing: nil)}
  end

  def handle_event("edit_host", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(id),
         {:ok, host} <- Hosts.get_host(id) do
      {:noreply,
       assign(socket,
         show_form: true,
         editing: host,
         form: to_form(Hosts.change_host(host))
       )}
    else
      _ -> {:noreply, put_flash(socket, :error, "Host no longer exists.")}
    end
  end

  def handle_event("save_host", %{"host" => params}, socket) do
    creating? = socket.assigns.editing == nil

    result =
      if socket.assigns.editing do
        Hosts.update_host(socket.assigns.editing, params)
      else
        Hosts.create_host(params)
      end

    case result do
      {:ok, host} ->
        action = if socket.assigns.editing, do: "updated", else: "created"
        hosts_count = socket.assigns.hosts_count + if(creating?, do: 1, else: 0)

        {:noreply,
         socket
         |> assign(show_form: false, editing: nil, hosts_empty?: false, hosts_count: hosts_count)
         |> stream_insert(:hosts, host)
         |> put_flash(:info, "Host #{action}.")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(:error, "Failed to save host.")}
    end
  end

  def handle_event("delete_host", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(id),
         {:ok, host} <- Hosts.get_host(id) do
      case Hosts.delete_host(host) do
        {:ok, deleted} ->
          hosts_count = max(socket.assigns.hosts_count - 1, 0)

          {:noreply,
           socket
           |> assign(hosts_empty?: hosts_count == 0, hosts_count: hosts_count)
           |> stream_delete(:hosts, deleted)
           |> put_flash(:info, "Host deleted.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete host.")}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "Host no longer exists.")}
    end
  end
end
