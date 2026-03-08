defmodule TimelessUIWeb.PollerLive.Schedules do
  use TimelessUIWeb, :live_view

  alias TimelessUI.Poller.{Schedules, Schedule}
  alias Ecto.Changeset

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Poller Schedules",
       schedules: Schedules.list_schedules(),
       show_form: false,
       editing: nil,
       changeset: Schedules.change_schedule(%Schedule{})
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-8">
      <div class="flex items-center justify-between mb-8">
        <div class="flex items-center gap-4">
          <.link navigate={~p"/poller"} class="btn btn-sm btn-ghost">&larr; Dashboard</.link>
          <h1 class="text-2xl font-bold">Poller Schedules</h1>
        </div>
        <button :if={!@show_form} phx-click="show_add_form" class="btn btn-primary">
          Add Schedule
        </button>
      </div>

      <.schedule_form :if={@show_form} changeset={@changeset} editing={@editing} />

      <div :if={@schedules == []} class="text-center text-base-content/60 py-16">
        <p class="text-lg mb-4">No schedules configured</p>
        <p>Click "Add Schedule" to define when polling jobs run.</p>
      </div>

      <div :if={@schedules != []} class="overflow-x-auto">
        <table class="table table-zebra">
          <thead>
            <tr>
              <th>Name</th>
              <th>Cron</th>
              <th>Host Tags</th>
              <th>Request Tags</th>
              <th>Enabled</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= for schedule <- @schedules do %>
              <tr>
                <td class="font-medium">{schedule.name}</td>
                <td class="font-mono text-sm">{schedule.cron}</td>
                <td class="text-sm">{display_tags(schedule.host_tags)}</td>
                <td class="text-sm">{display_tags(schedule.request_tags)}</td>
                <td>
                  <button
                    phx-click="toggle_enabled"
                    phx-value-id={schedule.id}
                    class={[
                      "btn btn-xs",
                      if(schedule.enabled, do: "btn-success", else: "btn-ghost")
                    ]}
                  >
                    {if schedule.enabled, do: "Enabled", else: "Disabled"}
                  </button>
                </td>
                <td>
                  <div class="flex gap-1">
                    <button
                      phx-click="edit_schedule"
                      phx-value-id={schedule.id}
                      class="btn btn-xs btn-ghost"
                    >
                      Edit
                    </button>
                    <button
                      phx-click="delete_schedule"
                      phx-value-id={schedule.id}
                      data-confirm={"Delete schedule \"#{schedule.name}\"? This cannot be undone."}
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

  defp schedule_form(assigns) do
    ~H"""
    <div class="card bg-base-200 mb-8">
      <div class="card-body">
        <h2 class="card-title mb-4">
          {if @editing, do: "Edit Schedule", else: "Add Schedule"}
        </h2>
        <form phx-submit="save_schedule">
          <div class="grid grid-cols-2 gap-6 mb-6">
            <div>
              <div class="text-sm text-base-content/70 mb-2">Name *</div>
              <input
                type="text"
                name="schedule[name]"
                value={Changeset.get_field(@changeset, :name)}
                required
                class="input input-bordered w-full"
                placeholder="eureka-ifx-5m"
              />
            </div>
            <div>
              <div class="text-sm text-base-content/70 mb-2">Cron Expression *</div>
              <input
                type="text"
                name="schedule[cron]"
                value={Changeset.get_field(@changeset, :cron)}
                required
                class="input input-bordered font-mono w-full"
                placeholder="*/5 * * * *"
              />
            </div>
          </div>
          <div class="grid grid-cols-2 gap-6 mb-6">
            <div>
              <div class="text-sm text-base-content/70 mb-2">
                Host Tags <span class="text-base-content/40">(blank = all)</span>
              </div>
              <input
                type="text"
                name="schedule[host_tags]"
                value={Changeset.get_field(@changeset, :host_tags) || ""}
                class="input input-bordered w-full"
                placeholder="cm, eureka"
              />
            </div>
            <div>
              <div class="text-sm text-base-content/70 mb-2">
                Request Tags <span class="text-base-content/40">(blank = all)</span>
              </div>
              <input
                type="text"
                name="schedule[request_tags]"
                value={Changeset.get_field(@changeset, :request_tags) || ""}
                class="input input-bordered w-full"
                placeholder="ifX"
              />
            </div>
          </div>
          <div class="flex items-center gap-3 mb-6">
            <input type="hidden" name="schedule[enabled]" value="false" />
            <input
              type="checkbox"
              name="schedule[enabled]"
              value="true"
              checked={Changeset.get_field(@changeset, :enabled)}
              class="checkbox"
            />
            <span class="text-sm">Enabled</span>
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

  defp display_tags(nil), do: "all"
  defp display_tags(""), do: "all"
  defp display_tags(tags), do: tags

  # --- Event Handlers ---

  @impl true
  def handle_event("show_add_form", _params, socket) do
    {:noreply,
     assign(socket,
       show_form: true,
       editing: nil,
       changeset: Schedules.change_schedule(%Schedule{})
     )}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply, assign(socket, show_form: false, editing: nil)}
  end

  def handle_event("edit_schedule", %{"id" => id}, socket) do
    schedule = Schedules.get_schedule!(id)

    {:noreply,
     assign(socket,
       show_form: true,
       editing: schedule,
       changeset: Schedules.change_schedule(schedule)
     )}
  end

  def handle_event("save_schedule", %{"schedule" => params}, socket) do
    params = parse_boolean_fields(params, ["enabled"])

    result =
      if socket.assigns.editing do
        Schedules.update_schedule(socket.assigns.editing, params)
      else
        Schedules.create_schedule(params)
      end

    case result do
      {:ok, _schedule} ->
        action = if socket.assigns.editing, do: "updated", else: "created"

        {:noreply,
         socket
         |> assign(show_form: false, editing: nil, schedules: Schedules.list_schedules())
         |> put_flash(:info, "Schedule #{action}.")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(changeset: changeset)
         |> put_flash(:error, "Failed to save schedule.")}
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    schedule = Schedules.get_schedule!(id)

    result =
      if schedule.enabled do
        Schedules.disable_schedule(schedule)
      else
        Schedules.enable_schedule(schedule)
      end

    case result do
      {:ok, _} ->
        {:noreply, assign(socket, schedules: Schedules.list_schedules())}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle schedule.")}
    end
  end

  def handle_event("delete_schedule", %{"id" => id}, socket) do
    schedule = Schedules.get_schedule!(id)

    case Schedules.delete_schedule(schedule) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(schedules: Schedules.list_schedules())
         |> put_flash(:info, "Schedule deleted.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete schedule.")}
    end
  end

  defp parse_boolean_fields(params, fields) do
    Enum.reduce(fields, params, fn field, acc ->
      case Map.get(acc, field) do
        "true" -> Map.put(acc, field, true)
        "false" -> Map.put(acc, field, false)
        _ -> acc
      end
    end)
  end
end
