defmodule TimelessUIWeb.PollerLive.Schedules do
  use TimelessUIWeb, :live_view

  alias TimelessUI.Poller.{Schedules, Schedule}

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
              <th>Host Groups</th>
              <th>Request Groups</th>
              <th>Enabled</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= for schedule <- @schedules do %>
              <tr>
                <td class="font-medium">{schedule.name}</td>
                <td class="font-mono text-sm">{schedule.cron}</td>
                <td class="text-sm">{format_groups(schedule.host_groups)}</td>
                <td class="text-sm">{format_groups(schedule.request_groups)}</td>
                <td>
                  <button
                    phx-click="toggle_enabled"
                    phx-value-id={schedule.id}
                    class={["btn btn-xs", if(schedule.enabled, do: "btn-success", else: "btn-ghost")]}
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
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div class="form-control">
              <label class="label"><span class="label-text">Name *</span></label>
              <input
                type="text"
                name="schedule[name]"
                value={Ecto.Changeset.get_field(@changeset, :name)}
                required
                class="input input-bordered"
                placeholder="e.g. every-5m-ping"
              />
            </div>
            <div class="form-control">
              <label class="label"><span class="label-text">Cron Expression *</span></label>
              <input
                type="text"
                name="schedule[cron]"
                value={Ecto.Changeset.get_field(@changeset, :cron)}
                required
                class="input input-bordered font-mono"
                placeholder="*/5 * * * *"
              />
            </div>
            <div class="form-control sm:col-span-2">
              <label class="label"><span class="label-text">Host Groups (JSON)</span></label>
              <textarea
                name="schedule[host_groups]"
                class="textarea textarea-bordered font-mono text-sm"
                rows="2"
                placeholder={~s|{"region": "us-east"}|}
              >{encode_json(Ecto.Changeset.get_field(@changeset, :host_groups))}</textarea>
            </div>
            <div class="form-control sm:col-span-2">
              <label class="label"><span class="label-text">Request Groups (JSON)</span></label>
              <textarea
                name="schedule[request_groups]"
                class="textarea textarea-bordered font-mono text-sm"
                rows="2"
                placeholder={~s|{"role": "router"}|}
              >{encode_json(Ecto.Changeset.get_field(@changeset, :request_groups))}</textarea>
            </div>
            <div class="form-control">
              <label class="label cursor-pointer justify-start gap-3">
                <input type="hidden" name="schedule[enabled]" value="false" />
                <input
                  type="checkbox"
                  name="schedule[enabled]"
                  value="true"
                  checked={Ecto.Changeset.get_field(@changeset, :enabled)}
                  class="checkbox"
                />
                <span class="label-text">Enabled</span>
              </label>
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
    params = parse_json_fields(params, ["host_groups", "request_groups"])
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
