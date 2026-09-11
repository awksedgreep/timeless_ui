defmodule TimelessUIWeb.PollerLive.Schedules do
  use TimelessUIWeb, :live_view

  import TimelessUIWeb.PollerNav

  alias TimelessUI.Poller.{Schedules, Schedule}

  @impl true
  def mount(_params, _session, socket) do
    schedules = Schedules.list_schedules()

    {:ok,
     socket
     |> assign(
       page_title: "Poller Schedules",
       schedules_empty?: schedules == [],
       schedules_count: length(schedules),
       show_form: false,
       editing: nil,
       form: to_form(Schedules.change_schedule(%Schedule{}))
     )
     |> stream(:schedules, schedules)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="poller-schedules-page" class="max-w-4xl mx-auto p-8">
        <.poller_nav current={:schedules} />

        <div class="flex items-center justify-between mb-8">
          <h1 class="text-2xl font-bold">Poller Schedules</h1>
          <button :if={!@show_form} phx-click="show_add_form" class="btn btn-primary">
            Add Schedule
          </button>
        </div>

        <.schedule_form :if={@show_form} form={@form} editing={@editing} />

        <div :if={@schedules_empty?} class="text-center text-base-content/60 py-16">
          <p class="text-lg mb-4">No schedules configured</p>
          <p>Click "Add Schedule" to define when polling jobs run.</p>
        </div>

        <div class={["overflow-x-auto", @schedules_empty? && "hidden"]}>
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
            <tbody id="poller-schedules" phx-update="stream">
              <tr :for={{id, schedule} <- @streams.schedules} id={id}>
                <td class="font-medium">{schedule.name}</td>
                <td class="font-mono text-sm">{schedule.cron}</td>
                <td class="text-sm">{display_tags(schedule.host_tags)}</td>
                <td class="text-sm">{display_tags(schedule.request_tags)}</td>
                <td>
                  <button
                    phx-click="toggle_enabled"
                    id={"toggle-schedule-#{schedule.id}"}
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
                      id={"edit-schedule-#{schedule.id}"}
                      phx-value-id={schedule.id}
                      class="btn btn-xs btn-ghost"
                    >
                      Edit
                    </button>
                    <button
                      phx-click="delete_schedule"
                      id={"delete-schedule-#{schedule.id}"}
                      phx-value-id={schedule.id}
                      data-confirm={"Delete schedule \"#{schedule.name}\"? This cannot be undone."}
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

  defp schedule_form(assigns) do
    ~H"""
    <div class="card bg-base-200 mb-8">
      <div class="card-body">
        <h2 class="card-title mb-4">
          {if @editing, do: "Edit Schedule", else: "Add Schedule"}
        </h2>
        <.form for={@form} id="poller-schedule-form" phx-submit="save_schedule">
          <div class="grid grid-cols-2 gap-6 mb-6">
            <.input
              field={@form[:name]}
              type="text"
              label="Name"
              required
              placeholder="eureka-ifx-5m"
            />
            <.input
              field={@form[:cron]}
              type="text"
              label="Cron Expression"
              required
              placeholder="*/5 * * * *"
            />
          </div>
          <div class="grid grid-cols-2 gap-6 mb-6">
            <div>
              <div class="text-sm text-base-content/70 mb-2">
                Host Tags <span class="text-base-content/40">(blank = all)</span>
              </div>
              <.input field={@form[:host_tags]} type="text" placeholder="cm, eureka" />
            </div>
            <div>
              <div class="text-sm text-base-content/70 mb-2">
                Request Tags <span class="text-base-content/40">(blank = all)</span>
              </div>
              <.input field={@form[:request_tags]} type="text" placeholder="ifX" />
            </div>
          </div>
          <div class="flex items-center gap-3 mb-6">
            <.input field={@form[:enabled]} type="checkbox" label="Enabled" />
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
       form: to_form(Schedules.change_schedule(%Schedule{}))
     )}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply, assign(socket, show_form: false, editing: nil)}
  end

  def handle_event("edit_schedule", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(id),
         {:ok, schedule} <- Schedules.get_schedule(id) do
      {:noreply,
       assign(socket,
         show_form: true,
         editing: schedule,
         form: to_form(Schedules.change_schedule(schedule))
       )}
    else
      _ -> {:noreply, put_flash(socket, :error, "Schedule no longer exists.")}
    end
  end

  def handle_event("save_schedule", %{"schedule" => params}, socket) do
    creating? = socket.assigns.editing == nil
    params = parse_boolean_fields(params, ["enabled"])

    result =
      if socket.assigns.editing do
        Schedules.update_schedule(socket.assigns.editing, params)
      else
        Schedules.create_schedule(params)
      end

    case result do
      {:ok, schedule} ->
        action = if socket.assigns.editing, do: "updated", else: "created"
        schedules_count = socket.assigns.schedules_count + if(creating?, do: 1, else: 0)

        {:noreply,
         socket
         |> assign(
           show_form: false,
           editing: nil,
           schedules_empty?: false,
           schedules_count: schedules_count
         )
         |> stream_insert(:schedules, schedule)
         |> put_flash(:info, "Schedule #{action}.")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(:error, "Failed to save schedule.")}
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(id),
         {:ok, schedule} <- Schedules.get_schedule(id) do
      result =
        if schedule.enabled do
          Schedules.disable_schedule(schedule)
        else
          Schedules.enable_schedule(schedule)
        end

      case result do
        {:ok, schedule} ->
          {:noreply, stream_insert(socket, :schedules, schedule)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to toggle schedule.")}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "Schedule no longer exists.")}
    end
  end

  def handle_event("delete_schedule", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(id),
         {:ok, schedule} <- Schedules.get_schedule(id) do
      case Schedules.delete_schedule(schedule) do
        {:ok, deleted} ->
          schedules_count = max(socket.assigns.schedules_count - 1, 0)

          {:noreply,
           socket
           |> assign(schedules_empty?: schedules_count == 0, schedules_count: schedules_count)
           |> stream_delete(:schedules, deleted)
           |> put_flash(:info, "Schedule deleted.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete schedule.")}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "Schedule no longer exists.")}
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
