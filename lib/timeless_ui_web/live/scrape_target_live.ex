defmodule TimelessUIWeb.ScrapeTargetLive do
  use TimelessUIWeb, :live_view

  alias TimelessUI.MetricsAPI

  @refresh_interval :timer.seconds(15)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_interval)

    {:ok,
     socket
     |> assign(
       page_title: "Scrape Targets",
       targets: [],
       loading: true,
       show_form: false,
       editing: nil,
       form: default_form(),
       expanded_id: nil
     )
     |> load_targets()}
  end

  defp load_targets(socket) do
    case MetricsAPI.list_targets() do
      {:ok, targets} ->
        assign(socket, targets: targets, loading: false)

      {:error, reason} ->
        socket
        |> assign(targets: [], loading: false)
        |> put_flash(:error, "Failed to load targets: #{inspect(reason)}")
    end
  end

  defp default_form do
    %{
      job_name: "",
      address: "",
      scheme: "http",
      metrics_path: "/metrics",
      scrape_interval: "30",
      scrape_timeout: "10",
      labels: [blank_label_row()]
    }
  end

  defp target_to_form(target) do
    %{
      job_name: target.job_name || "",
      address: target.address || "",
      scheme: target.scheme || "http",
      metrics_path: target.metrics_path || "/metrics",
      scrape_interval: to_string(target.scrape_interval || 30),
      scrape_timeout: to_string(target.scrape_timeout || 10),
      labels: labels_to_rows(target.labels)
    }
  end

  # Rebuild the form from what was submitted so a validation failure does not
  # discard everything the operator typed.
  defp params_to_form(params) do
    %{
      job_name: params["job_name"] || "",
      address: params["address"] || "",
      scheme: params["scheme"] || "http",
      metrics_path: params["metrics_path"] || "/metrics",
      scrape_interval: params["scrape_interval"] || "30",
      scrape_timeout: params["scrape_timeout"] || "10",
      labels: params_to_label_rows(params["labels"])
    }
  end

  defp blank_label_row, do: %{"key" => "", "value" => ""}

  # A stored map becomes editable rows, always with one blank row on the end so
  # there is somewhere to type without hunting for an "add" button first.
  defp labels_to_rows(labels) when is_map(labels) and map_size(labels) > 0 do
    labels
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.map(fn {key, value} -> %{"key" => key, "value" => to_string(value)} end)
    |> Kernel.++([blank_label_row()])
  end

  defp labels_to_rows(_), do: [blank_label_row()]

  # Rows arrive as %{"0" => %{"key" => ..., "value" => ...}}; the string indices
  # are ordered numerically so the rows do not shuffle on re-render.
  defp params_to_label_rows(rows) when is_map(rows) do
    rows
    |> Enum.sort_by(fn {index, _} -> String.to_integer(index) end)
    |> Enum.map(fn {_index, row} ->
      %{"key" => row["key"] || "", "value" => row["value"] || ""}
    end)
    |> case do
      [] -> [blank_label_row()]
      parsed -> parsed
    end
  end

  defp params_to_label_rows(_), do: [blank_label_row()]

  # Rows with no key are simply unfilled, not an error worth stopping a save for.
  defp rows_to_labels(rows) do
    rows
    |> Enum.reject(fn row -> String.trim(row["key"] || "") == "" end)
    |> Map.new(fn row -> {String.trim(row["key"]), String.trim(row["value"] || "")} end)
  end

  # `||` cannot default a boolean: `false || true` is `true`, so a saved false
  # rendered as checked and the stored value could never be seen. Only nil,
  # meaning "not set", should fall back to the default.
  defp bool_or(nil, default), do: default
  defp bool_or(value, _default), do: value

  defp field_label("scrape_timeout"), do: "Scrape timeout"
  defp field_label("labels"), do: "Labels"
  defp field_label(field), do: field

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-8">
      <div class="flex items-center justify-between mb-8">
        <h1 class="text-2xl font-bold">Scrape Targets</h1>
        <button :if={!@show_form} phx-click="show_add_form" class="btn btn-primary">
          Add Target
        </button>
      </div>

      <.form_section
        :if={@show_form}
        form={@form}
        editing={@editing}
      />

      <div :if={@loading} class="text-center py-16">
        <span class="loading loading-spinner loading-lg"></span>
      </div>

      <div :if={!@loading && @targets == []} class="text-center text-base-content/60 py-16">
        <p class="text-lg mb-4">No scrape targets configured</p>
        <p>Click "Add Target" to start scraping Prometheus endpoints.</p>
      </div>

      <div :if={!@loading && @targets != []} class="overflow-x-auto">
        <table class="table table-zebra">
          <thead>
            <tr>
              <th>Job Name</th>
              <th>Address</th>
              <th>Interval</th>
              <th>Health</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= for target <- @targets do %>
              <tr
                class="cursor-pointer hover"
                phx-click="toggle_expand"
                phx-value-id={target.id}
              >
                <td class="font-medium">{target.job_name}</td>
                <td class="font-mono text-sm">
                  {target.scheme}://{target.address}{target.metrics_path}
                </td>
                <td>{target.scrape_interval}s</td>
                <td><.health_badge health={target.health} /></td>
                <td>
                  <div class="flex gap-1">
                    <button
                      phx-click="edit_target"
                      phx-value-id={target.id}
                      class="btn btn-xs btn-ghost"
                    >
                      Edit
                    </button>
                    <button
                      phx-click="delete_target"
                      phx-value-id={target.id}
                      data-confirm={"Delete target \"#{target.job_name}\"? This cannot be undone."}
                      class="btn btn-xs btn-error btn-outline"
                    >
                      Delete
                    </button>
                  </div>
                </td>
              </tr>
              <tr :if={@expanded_id == target.id}>
                <td colspan="5" class="bg-base-200">
                  <.target_details target={target} />
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  @doc false
  # Public so the badge can be rendered directly in tests.
  def health_badge(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5">
      <span class={["w-2.5 h-2.5 rounded-full", health_color(@health)]}></span>
      <span class="text-sm">{health_label(@health)}</span>
    </div>
    """
  end

  # health arrives as the string the data plane reported, not a map: the badge is
  # called as <.health_badge health={target.health} />. Matching on %{health: ...}
  # never succeeded, so every target rendered grey and "unknown" no matter what
  # it was actually doing — the same flat-versus-nested confusion that crashed
  # target_details, except this end failed silently.
  defp health_color("up"), do: "bg-success"
  defp health_color("down"), do: "bg-error"
  defp health_color(_), do: "bg-base-content/30"

  defp health_label(health) when is_binary(health) and health != "", do: health
  defp health_label(_), do: "unknown"

  defp target_details(assigns) do
    ~H"""
    <div class="grid grid-cols-2 sm:grid-cols-4 gap-4 p-2 text-sm">
      <div>
        <span class="text-base-content/60">Last Scrape</span>
        <p class="font-medium">{format_timestamp(@target.last_scrape)}</p>
      </div>
      <div>
        <span class="text-base-content/60">Duration</span>
        <p class="font-medium">{format_duration(@target.last_duration_ms)}</p>
      </div>
      <div>
        <span class="text-base-content/60">Samples</span>
        <p class="font-medium">{@target.samples_scraped || "—"}</p>
      </div>
      <div>
        <span class="text-base-content/60">Error</span>
        <p class={["font-medium", @target.last_error && "text-error"]}>
          {@target.last_error || "—"}
        </p>
      </div>
    </div>
    """
  end

  defp format_timestamp(nil), do: "—"

  defp format_timestamp(unix) when is_integer(unix) do
    unix
    |> DateTime.from_unix!()
    |> Calendar.strftime("%b %d %H:%M:%S")
  end

  defp format_duration(nil), do: "—"
  defp format_duration(ms), do: "#{ms}ms"

  defp form_section(assigns) do
    ~H"""
    <div class="card bg-base-200 mb-8">
      <div class="card-body">
        <h2 class="card-title mb-4">
          {if @editing, do: "Edit Target", else: "Add Target"}
        </h2>
        <form phx-submit="save_target" phx-change="form_changed">
          <input :if={@editing} type="hidden" name="target_id" value={@editing} />
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div class="form-control">
              <label class="label"><span class="label-text">Job Name *</span></label>
              <input
                type="text"
                name="job_name"
                value={@form.job_name}
                required
                class="input input-bordered"
                placeholder="e.g. node_exporter"
              />
            </div>
            <div class="form-control">
              <label class="label"><span class="label-text">Address *</span></label>
              <input
                type="text"
                name="address"
                value={@form.address}
                required
                class="input input-bordered"
                placeholder="e.g. localhost:9100"
              />
            </div>
            <div class="form-control">
              <label class="label"><span class="label-text">Scheme</span></label>
              <select name="scheme" class="select select-bordered">
                <option value="http" selected={@form.scheme == "http"}>http</option>
                <option value="https" selected={@form.scheme == "https"}>https</option>
              </select>
            </div>
            <div class="form-control">
              <label class="label"><span class="label-text">Metrics Path</span></label>
              <input
                type="text"
                name="metrics_path"
                value={@form.metrics_path}
                class="input input-bordered"
                placeholder="/metrics"
              />
            </div>
            <div class="form-control">
              <label class="label"><span class="label-text">Scrape Interval (s)</span></label>
              <input
                type="number"
                name="scrape_interval"
                value={@form.scrape_interval}
                min="1"
                class="input input-bordered"
              />
            </div>
            <div class="form-control">
              <label class="label"><span class="label-text">Scrape Timeout (s)</span></label>
              <input
                type="number"
                name="scrape_timeout"
                value={@form.scrape_timeout}
                min="1"
                class="input input-bordered"
              />
            </div>
          </div>

          <div class="form-control mt-4">
            <label class="label">
              <span class="label-text">Labels</span>
            </label>
            <p class="text-sm text-base-content/60 -mt-1 mb-2">
              Added to every metric from this target. Nothing else identifies where a
              metric came from, so without at least a <code>host</code> label these
              series cannot be attached to a host or found on a canvas.
            </p>
            <div class="space-y-2">
              <div :for={{row, index} <- Enum.with_index(@form.labels)} class="flex gap-2">
                <input
                  type="text"
                  name={"labels[#{index}][key]"}
                  value={row["key"]}
                  class="input input-bordered input-sm flex-1"
                  placeholder="host"
                />
                <input
                  type="text"
                  name={"labels[#{index}][value]"}
                  value={row["value"]}
                  class="input input-bordered input-sm flex-1"
                  placeholder="my-server"
                />
                <button
                  type="button"
                  phx-click="remove_label"
                  phx-value-index={index}
                  class="btn btn-sm btn-ghost"
                  aria-label="Remove label"
                >
                  &times;
                </button>
              </div>
            </div>
            <button type="button" phx-click="add_label" class="btn btn-sm btn-ghost mt-2 self-start">
              + Add label
            </button>
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

  # --- Event Handlers ---

  @impl true
  def handle_event("show_add_form", _params, socket) do
    {:noreply,
     assign(socket, show_form: true, editing: nil, form: default_form())}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply, assign(socket, show_form: false, editing: nil)}
  end

  def handle_event("toggle_expand", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    new_id = if socket.assigns.expanded_id == id, do: nil, else: id
    {:noreply, assign(socket, expanded_id: new_id)}
  end

  def handle_event("edit_target", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)

    case MetricsAPI.get_target(id) do
      {:ok, target} ->
        {:noreply,
         assign(socket,
           show_form: true,
           editing: id,
           form: target_to_form(target)
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not load target")}
    end
  end

  def handle_event("save_target", params, socket) do
    case build_api_params(params) do
      {:error, field, message} ->
        {:noreply,
         socket
         |> assign(form: params_to_form(params))
         |> put_flash(:error, "#{field_label(field)} #{message}")}

      {:ok, api_params} ->
        save_target(socket, api_params)
    end
  end

  # Without this the form would lose everything typed so far the moment a label
  # row is added or removed, since those re-render the form from assigns.
  def handle_event("form_changed", params, socket) do
    {:noreply, assign(socket, form: params_to_form(params))}
  end

  def handle_event("add_label", _params, socket) do
    rows = socket.assigns.form.labels ++ [blank_label_row()]
    {:noreply, assign(socket, form: %{socket.assigns.form | labels: rows})}
  end

  def handle_event("remove_label", %{"index" => index}, socket) do
    rows =
      socket.assigns.form.labels
      |> List.delete_at(String.to_integer(index))
      |> case do
        [] -> [blank_label_row()]
        remaining -> remaining
      end

    {:noreply, assign(socket, form: %{socket.assigns.form | labels: rows})}
  end

  def handle_event("delete_target", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)

    case MetricsAPI.delete_target(id) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Target deleted.")
         |> load_targets()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, load_targets(socket)}
  end

  defp save_target(socket, api_params) do
    result =
      if socket.assigns.editing do
        MetricsAPI.update_target(socket.assigns.editing, api_params)
      else
        MetricsAPI.create_target(api_params)
      end

    case result do
      :ok ->
        {:noreply,
         socket
         |> assign(show_form: false, editing: nil)
         |> put_flash(:info, "Target updated.")
         |> load_targets()}

      {:ok, _id} ->
        {:noreply,
         socket
         |> assign(show_form: false, editing: nil)
         |> put_flash(:info, "Target created.")
         |> load_targets()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Error: #{inspect(reason)}")}
    end
  end

  # --- Helpers ---

  @doc false
  # Public so the JSON handling can be tested without driving the LiveView.
  def build_api_params(params) do
    base = %{
      "job_name" => params["job_name"],
      "address" => params["address"],
      "scheme" => params["scheme"] || "http",
      "metrics_path" => params["metrics_path"] || "/metrics",
      "scrape_interval" => parse_int(params["scrape_interval"], 30),
      "scrape_timeout" => parse_int(params["scrape_timeout"], 10)
    }

    base = Map.put(base, "labels", rows_to_labels(params_to_label_rows(params["labels"])))

    with :ok <- validate_timeout(base) do
      {:ok, base}
    end
  end

  # A timeout at or beyond the interval can never complete before the next scrape
  # is due. Prometheus rejects it, and silently accepting it here would produce a
  # target that looks configured and quietly overlaps itself.
  defp validate_timeout(%{"scrape_timeout" => timeout, "scrape_interval" => interval})
       when timeout >= interval do
    {:error, "scrape_timeout",
     "must be less than the scrape interval (#{interval}s), otherwise a scrape " <>
       "cannot finish before the next one is due"}
  end

  defp validate_timeout(_), do: :ok

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(str, default) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> default
    end
  end

  # A field that is absent from the submission is left alone; a field that is
  # present but blank is an instruction to clear it. Collapsing those two, as
  # this previously did, means a value can be set and edited but never removed.
  defp put_json(map, _key, nil, _empty), do: {:ok, map}

  defp put_json(map, key, str, empty) do
    case String.trim(str) do
      "" ->
        {:ok, Map.put(map, key, empty)}

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, val} ->
            {:ok, Map.put(map, key, val)}

          # Never discard input the operator typed. Silently dropping it produced
          # a target that reported healthy while storing series with none of the
          # labels that make them findable.
          {:error, error} ->
            {:error, key, "is not valid JSON: " <> Exception.message(error)}
        end
    end
  end
end
