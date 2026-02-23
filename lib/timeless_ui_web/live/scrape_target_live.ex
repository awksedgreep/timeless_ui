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
       show_advanced: false,
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
      labels: "",
      honor_labels: false,
      honor_timestamps: true,
      metric_relabel_configs: ""
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
      labels: encode_json(target.labels),
      honor_labels: target.honor_labels || false,
      honor_timestamps: target.honor_timestamps || true,
      metric_relabel_configs: encode_json(target.metric_relabel_configs)
    }
  end

  defp encode_json(nil), do: ""
  defp encode_json(val) when val == %{}, do: ""
  defp encode_json(val) when val == [], do: ""
  defp encode_json(val), do: Jason.encode!(val, pretty: true)

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
        show_advanced={@show_advanced}
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

  defp health_badge(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5">
      <span class={["w-2.5 h-2.5 rounded-full", health_color(@health)]}></span>
      <span class="text-sm">{health_label(@health)}</span>
    </div>
    """
  end

  defp health_color(%{health: "up"}), do: "bg-success"
  defp health_color(%{health: "down"}), do: "bg-error"
  defp health_color(_), do: "bg-base-content/30"

  defp health_label(%{health: h}), do: h
  defp health_label(_), do: "unknown"

  defp target_details(assigns) do
    ~H"""
    <div class="grid grid-cols-2 sm:grid-cols-4 gap-4 p-2 text-sm">
      <div>
        <span class="text-base-content/60">Last Scrape</span>
        <p class="font-medium">{format_timestamp(@target.health.last_scrape)}</p>
      </div>
      <div>
        <span class="text-base-content/60">Duration</span>
        <p class="font-medium">{format_duration(@target.health.last_duration_ms)}</p>
      </div>
      <div>
        <span class="text-base-content/60">Samples</span>
        <p class="font-medium">{@target.health.samples_scraped || "—"}</p>
      </div>
      <div>
        <span class="text-base-content/60">Error</span>
        <p class={["font-medium", @target.health.last_error && "text-error"]}>
          {@target.health.last_error || "—"}
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
        <form phx-submit="save_target">
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

          <div class="mt-4">
            <button
              type="button"
              phx-click="toggle_advanced"
              class="btn btn-sm btn-ghost gap-1"
            >
              <span :if={!@show_advanced}>&#9654;</span>
              <span :if={@show_advanced}>&#9660;</span>
              Advanced Options
            </button>
          </div>

          <div :if={@show_advanced} class="grid grid-cols-1 sm:grid-cols-2 gap-4 mt-4">
            <div class="form-control sm:col-span-2">
              <label class="label"><span class="label-text">Labels (JSON)</span></label>
              <textarea
                name="labels"
                class="textarea textarea-bordered font-mono text-sm"
                rows="3"
                placeholder={~s|{"env": "prod"}|}
              >{@form.labels}</textarea>
            </div>
            <div class="form-control">
              <label class="label cursor-pointer justify-start gap-3">
                <input
                  type="hidden"
                  name="honor_labels"
                  value="false"
                />
                <input
                  type="checkbox"
                  name="honor_labels"
                  value="true"
                  checked={@form.honor_labels}
                  class="checkbox"
                />
                <span class="label-text">Honor Labels</span>
              </label>
            </div>
            <div class="form-control">
              <label class="label cursor-pointer justify-start gap-3">
                <input
                  type="hidden"
                  name="honor_timestamps"
                  value="false"
                />
                <input
                  type="checkbox"
                  name="honor_timestamps"
                  value="true"
                  checked={@form.honor_timestamps}
                  class="checkbox"
                />
                <span class="label-text">Honor Timestamps</span>
              </label>
            </div>
            <div class="form-control sm:col-span-2">
              <label class="label">
                <span class="label-text">Metric Relabel Configs (JSON)</span>
              </label>
              <textarea
                name="metric_relabel_configs"
                class="textarea textarea-bordered font-mono text-sm"
                rows="4"
                placeholder={~s|[{"action": "keep", "source_labels": ["__name__"], "regex": "up"}]|}
              >{@form.metric_relabel_configs}</textarea>
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

  # --- Event Handlers ---

  @impl true
  def handle_event("show_add_form", _params, socket) do
    {:noreply, assign(socket, show_form: true, editing: nil, form: default_form(), show_advanced: false)}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply, assign(socket, show_form: false, editing: nil)}
  end

  def handle_event("toggle_advanced", _params, socket) do
    {:noreply, assign(socket, show_advanced: !socket.assigns.show_advanced)}
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
           form: target_to_form(target),
           show_advanced: false
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not load target")}
    end
  end

  def handle_event("save_target", params, socket) do
    api_params = build_api_params(params)

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

  # --- Helpers ---

  defp build_api_params(params) do
    base = %{
      "job_name" => params["job_name"],
      "address" => params["address"],
      "scheme" => params["scheme"] || "http",
      "metrics_path" => params["metrics_path"] || "/metrics",
      "scrape_interval" => parse_int(params["scrape_interval"], 30),
      "scrape_timeout" => parse_int(params["scrape_timeout"], 10),
      "honor_labels" => params["honor_labels"] == "true",
      "honor_timestamps" => params["honor_timestamps"] == "true"
    }

    base
    |> maybe_put_json("labels", params["labels"])
    |> maybe_put_json("metric_relabel_configs", params["metric_relabel_configs"])
  end

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(str, default) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> default
    end
  end

  defp maybe_put_json(map, _key, nil), do: map
  defp maybe_put_json(map, _key, ""), do: map

  defp maybe_put_json(map, key, str) do
    case Jason.decode(str) do
      {:ok, val} -> Map.put(map, key, val)
      {:error, _} -> map
    end
  end
end
