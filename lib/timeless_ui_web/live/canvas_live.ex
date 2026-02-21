defmodule TimelessUIWeb.CanvasLive do
  use TimelessUIWeb, :live_view

  alias TimelessUI.Canvas
  alias TimelessUI.Canvas.{ViewBox, History, Element, Connection, Serializer}
  alias TimelessUI.Canvases
  alias TimelessUI.Canvases.Policy
  alias TimelessUI.DataSource.Manager, as: StatusManager
  import TimelessUIWeb.CanvasComponents

  @type_labels %{
    rect: "Rect",
    server: "Server",
    service: "Service",
    database: "Database",
    load_balancer: "LB",
    queue: "Queue",
    cache: "Cache",
    network: "Network",
    graph: "Graph"
  }

  @tick_interval 200

  @impl true
  def mount(%{"id" => id_str}, _session, socket) do
    current_user = socket.assigns.current_scope.user

    with {canvas_id, ""} <- Integer.parse(id_str),
         {:ok, record} <- Canvases.get_canvas(canvas_id),
         :ok <- Policy.authorize(current_user, record, :view) do
      can_edit = Policy.authorize(current_user, record, :edit) == :ok
      is_owner = record.user_id == current_user.id || Policy.admin?(current_user)

      if connected?(socket) do
        Phoenix.PubSub.subscribe(TimelessUI.PubSub, StatusManager.topic())
        Phoenix.PubSub.subscribe(TimelessUI.PubSub, StatusManager.metric_topic())
      end

      canvas =
        case Serializer.decode(record.data) do
          {:ok, c} -> c
          {:error, _} -> Canvas.new()
        end

      history = History.new(canvas)

      if connected?(socket) and map_size(canvas.elements) > 0 do
        StatusManager.register_elements(Map.values(canvas.elements))
      end

      {:ok,
       assign(socket,
         history: history,
         canvas: canvas,
         selected_id: nil,
         mode: :select,
         place_type: :rect,
         connect_from: nil,
         canvas_name: record.name,
         canvas_id: canvas_id,
         user_id: current_user.id,
         can_edit: can_edit,
         is_owner: is_owner,
         show_share: false,
         page_title: "TimelessUI Canvas",
         # Timeline / time-travel assigns
         timeline_mode: :live,
         timeline_time: nil,
         timeline_playing: false,
         timeline_speed: 1.0,
         timeline_range: nil,
         playback_ref: nil,
         graph_data: %{}
       )}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Canvas not found or access denied")
         |> redirect(to: ~p"/canvases")}
    end
  end

  @max_graph_points 60

  @impl true
  def render(assigns) do
    assigns = assign(assigns, type_labels: @type_labels)

    ~H"""
    <div class={"canvas-container#{if selected_object(@selected_id, @canvas) != nil, do: " canvas-container--panel-open", else: ""}"}>
      <div class="canvas-toolbar">
        <span :if={!@can_edit} class="canvas-toolbar__badge canvas-toolbar__badge--readonly">
          View Only
        </span>
        <button
          phx-click="toggle_mode"
          phx-value-mode="select"
          class={"canvas-toolbar__btn#{if @mode == :select, do: " canvas-toolbar__btn--active", else: ""}"}
        >
          Select
        </button>
        <button
          phx-click="toggle_mode"
          phx-value-mode="place"
          class={"canvas-toolbar__btn#{if @mode == :place, do: " canvas-toolbar__btn--active", else: ""}"}
          disabled={!@can_edit}
        >
          Place
        </button>
        <button
          phx-click="toggle_mode"
          phx-value-mode="connect"
          class={"canvas-toolbar__btn#{if @mode == :connect, do: " canvas-toolbar__btn--active", else: ""}"}
          disabled={!@can_edit}
        >
          Connect
        </button>
        <span class="canvas-toolbar__sep"></span>

        <div :if={@mode == :place} class="canvas-type-palette">
          <button
            :for={type <- Element.element_types()}
            phx-click="set_place_type"
            phx-value-type={type}
            class={"canvas-toolbar__btn canvas-type-btn#{if @place_type == type, do: " canvas-toolbar__btn--active", else: ""}"}
            style={"border-bottom: 2px solid #{Element.defaults_for(type).color}"}
          >
            {@type_labels[type] || type}
          </button>
        </div>

        <span :if={@mode == :place} class="canvas-toolbar__sep"></span>

        <button
          phx-click="toggle_grid"
          class={"canvas-toolbar__btn#{if @canvas.grid_visible, do: " canvas-toolbar__btn--active", else: ""}"}
        >
          Grid
        </button>
        <button
          phx-click="toggle_snap"
          class={"canvas-toolbar__btn#{if @canvas.snap_to_grid, do: " canvas-toolbar__btn--active", else: ""}"}
        >
          Snap
        </button>
        <span class="canvas-toolbar__sep"></span>
        <button
          phx-click="canvas:undo"
          class="canvas-toolbar__btn"
          disabled={!@can_edit || !History.can_undo?(@history)}
        >
          Undo
        </button>
        <button
          phx-click="canvas:redo"
          class="canvas-toolbar__btn"
          disabled={!@can_edit || !History.can_redo?(@history)}
        >
          Redo
        </button>
        <span class="canvas-toolbar__sep"></span>
        <button
          phx-click="send_to_back"
          class="canvas-toolbar__btn"
          disabled={!@can_edit || is_nil(@selected_id)}
        >
          Back
        </button>
        <button
          phx-click="bring_to_front"
          class="canvas-toolbar__btn"
          disabled={!@can_edit || is_nil(@selected_id)}
        >
          Front
        </button>
        <button
          phx-click="delete_selected"
          class="canvas-toolbar__btn canvas-toolbar__btn--danger"
          disabled={!@can_edit || is_nil(@selected_id)}
        >
          Delete
        </button>
        <span :if={@is_owner} class="canvas-toolbar__sep"></span>
        <button
          :if={@is_owner}
          phx-click="toggle_share"
          class={"canvas-toolbar__btn#{if @show_share, do: " canvas-toolbar__btn--active", else: ""}"}
        >
          Share
        </button>
      </div>

      <div :if={@show_share && @is_owner} class="canvas-share-overlay">
        <.live_component
          module={TimelessUIWeb.CanvasShareComponent}
          id="canvas-share"
          canvas_id={@canvas_id}
        />
      </div>

      <svg
        id="canvas-svg"
        phx-hook="Canvas"
        viewBox={ViewBox.to_string(@canvas.view_box)}
        class="canvas-svg"
        data-mode={@mode}
        data-connect-from={@connect_from}
        data-grid-size={@canvas.grid_size}
      >
        <defs>
          <pattern
            id="grid-pattern"
            width={@canvas.grid_size}
            height={@canvas.grid_size}
            patternUnits="userSpaceOnUse"
          >
            <path
              d={"M #{@canvas.grid_size} 0 L 0 0 0 #{@canvas.grid_size}"}
              fill="none"
              stroke="var(--grid-color)"
              stroke-width="0.5"
            />
          </pattern>
        </defs>

        <rect
          :if={@canvas.grid_visible}
          x={@canvas.view_box.min_x - @canvas.view_box.width}
          y={@canvas.view_box.min_y - @canvas.view_box.height}
          width={@canvas.view_box.width * 3}
          height={@canvas.view_box.height * 3}
          fill="url(#grid-pattern)"
          class="canvas-grid"
        />

        <.canvas_connection
          :for={{_id, conn} <- @canvas.connections}
          connection={conn}
          source={@canvas.elements[conn.source_id]}
          target={@canvas.elements[conn.target_id]}
          selected={conn.id == @selected_id}
        />

        <.canvas_element
          :for={element <- sorted_elements(@canvas.elements)}
          :key={element.id}
          element={element}
          selected={element.id == @selected_id}
          graph_points={graph_points_for(element, @graph_data)}
          graph_value={graph_value_for(element, @graph_data)}
        />
      </svg>

      <.properties_panel
        selected={selected_object(@selected_id, @canvas)}
        selected_id={@selected_id}
        canvas={@canvas}
      />

      <.timeline_bar
        timeline_mode={@timeline_mode}
        timeline_time={@timeline_time}
        timeline_playing={@timeline_playing}
        timeline_speed={@timeline_speed}
        timeline_range={@timeline_range}
      />

      <div class="canvas-zoom-indicator">
        {zoom_percentage(@canvas.view_box)}%
      </div>
    </div>
    """
  end

  # --- Properties Panel ---

  defp properties_panel(%{selected: nil} = assigns) do
    ~H""
  end

  defp properties_panel(%{selected: %Element{}} = assigns) do
    assigns = assign(assigns, meta_fields: Element.meta_fields(assigns.selected.type))

    ~H"""
    <div class="properties-panel">
      <h3 class="properties-panel__title">Element Properties</h3>
      <form phx-change="property:update_element" phx-submit="property:update_element">
        <input type="hidden" name="element_id" value={@selected.id} />
        <div class="properties-panel__field">
          <label>Label</label>
          <input type="text" name="label" value={@selected.label} />
        </div>
        <div class="properties-panel__field">
          <label>Type</label>
          <select name="type">
            <option :for={t <- Element.element_types()} value={t} selected={t == @selected.type}>
              {t}
            </option>
          </select>
        </div>
        <div class="properties-panel__field">
          <label>Color</label>
          <input type="color" name="color" value={@selected.color} />
        </div>
        <div class="properties-panel__row">
          <div class="properties-panel__field">
            <label>X</label>
            <input type="number" name="x" value={round(@selected.x)} step="1" />
          </div>
          <div class="properties-panel__field">
            <label>Y</label>
            <input type="number" name="y" value={round(@selected.y)} step="1" />
          </div>
        </div>
        <div class="properties-panel__row">
          <div class="properties-panel__field">
            <label>Width</label>
            <input type="number" name="width" value={round(@selected.width)} step="1" min="20" />
          </div>
          <div class="properties-panel__field">
            <label>Height</label>
            <input type="number" name="height" value={round(@selected.height)} step="1" min="20" />
          </div>
        </div>
      </form>
      <div :if={@meta_fields != []} class="properties-panel__section">
        <h4 class="properties-panel__subtitle">Metadata</h4>
        <form phx-change="property:update_meta" phx-submit="property:update_meta">
          <input type="hidden" name="element_id" value={@selected.id} />
          <div :for={field <- @meta_fields} class="properties-panel__field">
            <label>{field}</label>
            <input type="text" name={field} value={@selected.meta[field] || ""} />
          </div>
        </form>
      </div>
    </div>
    """
  end

  defp properties_panel(%{selected: %Connection{}} = assigns) do
    ~H"""
    <div class="properties-panel">
      <h3 class="properties-panel__title">Connection Properties</h3>
      <form phx-change="property:update_connection" phx-submit="property:update_connection">
        <input type="hidden" name="conn_id" value={@selected.id} />
        <div class="properties-panel__field">
          <label>Label</label>
          <input type="text" name="label" value={@selected.label} />
        </div>
        <div class="properties-panel__field">
          <label>Color</label>
          <input type="color" name="color" value={@selected.color} />
        </div>
        <div class="properties-panel__field">
          <label>Style</label>
          <select name="style">
            <option value="solid" selected={@selected.style == :solid}>Solid</option>
            <option value="dashed" selected={@selected.style == :dashed}>Dashed</option>
            <option value="dotted" selected={@selected.style == :dotted}>Dotted</option>
          </select>
        </div>
        <div class="properties-panel__field">
          <label>Source</label>
          <input type="text" value={@selected.source_id} disabled />
        </div>
        <div class="properties-panel__field">
          <label>Target</label>
          <input type="text" value={@selected.target_id} disabled />
        </div>
      </form>
    </div>
    """
  end

  defp selected_object(nil, _canvas), do: nil

  defp selected_object("el-" <> _ = id, canvas) do
    Map.get(canvas.elements, id)
  end

  defp selected_object("conn-" <> _ = id, canvas) do
    Map.get(canvas.connections, id)
  end

  defp selected_object(_id, _canvas), do: nil

  defp zoom_percentage(%ViewBox{width: width}) do
    round(1200.0 / width * 100)
  end

  # --- Helpers ---

  defp push_canvas(socket, %Canvas{} = canvas) do
    history = History.push(socket.assigns.history, canvas)
    assign(socket, history: history, canvas: history.present)
  end

  defp update_canvas(socket, %Canvas{} = canvas) do
    history = %{socket.assigns.history | present: canvas}
    assign(socket, history: history, canvas: canvas)
  end

  defp register_elements(socket) do
    elements = Map.values(socket.assigns.canvas.elements)
    StatusManager.register_elements(elements)
    socket
  end

  defp schedule_autosave(socket) do
    if Map.get(socket.assigns, :autosave_ref) do
      Process.cancel_timer(socket.assigns.autosave_ref)
    end

    ref = Process.send_after(self(), :autosave, 2000)
    assign(socket, autosave_ref: ref)
  end

  defp apply_statuses(canvas, statuses) do
    Enum.reduce(statuses, canvas, fn {id, status}, acc ->
      Canvas.set_element_status(acc, id, status)
    end)
  end

  defp start_playback(socket) do
    ref = Process.send_after(self(), :timeline_tick, @tick_interval)
    assign(socket, playback_ref: ref, timeline_playing: true)
  end

  defp stop_playback(socket) do
    if socket.assigns.playback_ref do
      Process.cancel_timer(socket.assigns.playback_ref)
    end

    assign(socket, playback_ref: nil, timeline_playing: false)
  end

  # --- Event Handlers ---

  @impl true
  def handle_event("canvas:pan", %{"dx" => dx, "dy" => dy}, socket) do
    canvas = Canvas.pan(socket.assigns.canvas, dx, dy)
    {:noreply, update_canvas(socket, canvas)}
  end

  def handle_event(
        "canvas:zoom",
        %{"min_x" => min_x, "min_y" => min_y, "width" => width, "height" => height},
        socket
      ) do
    vb = %ViewBox{
      min_x: min_x / 1,
      min_y: min_y / 1,
      width: max(width / 1, 100.0),
      height: max(height / 1, 100.0)
    }

    canvas = %{socket.assigns.canvas | view_box: vb}
    {:noreply, update_canvas(socket, canvas)}
  end

  def handle_event("canvas:click", %{"x" => x, "y" => y}, socket) do
    case socket.assigns.mode do
      :place ->
        require_edit(socket, fn ->
          type = socket.assigns.place_type
          defaults = Element.defaults_for(type)

          {canvas, _el} =
            Canvas.add_element(socket.assigns.canvas, %{
              type: type,
              x: x / 1.0,
              y: y / 1.0,
              color: defaults.color,
              width: defaults.width,
              height: defaults.height,
              label: "#{@type_labels[type] || type} #{socket.assigns.canvas.next_id}"
            })

          {:noreply, push_canvas(socket, canvas) |> schedule_autosave()}
        end)

      :connect ->
        {:noreply, assign(socket, connect_from: nil)}

      :select ->
        {:noreply, assign(socket, selected_id: nil)}
    end
  end

  def handle_event("element:select", %{"id" => id}, socket) do
    case socket.assigns.mode do
      :connect ->
        require_edit(socket, fn ->
          case socket.assigns.connect_from do
            nil ->
              {:noreply, assign(socket, connect_from: id)}

            ^id ->
              # Can't connect to self
              {:noreply, assign(socket, connect_from: nil)}

            from_id ->
              {canvas, _conn} = Canvas.add_connection(socket.assigns.canvas, from_id, id)

              {:noreply,
               push_canvas(socket, canvas) |> assign(connect_from: nil) |> schedule_autosave()}
          end
        end)

      _ ->
        {:noreply, assign(socket, selected_id: id)}
    end
  end

  def handle_event("connection:select", %{"id" => id}, socket) do
    {:noreply, assign(socket, selected_id: id)}
  end

  def handle_event("element:move", %{"id" => id, "dx" => dx, "dy" => dy}, socket) do
    require_edit(socket, fn ->
      canvas = Canvas.move_element(socket.assigns.canvas, id, dx / 1.0, dy / 1.0)
      {:noreply, push_canvas(socket, canvas) |> schedule_autosave()}
    end)
  end

  def handle_event("element:resize", %{"id" => id, "width" => width, "height" => height}, socket) do
    require_edit(socket, fn ->
      canvas = Canvas.resize_element(socket.assigns.canvas, id, width / 1.0, height / 1.0)
      {:noreply, push_canvas(socket, canvas) |> schedule_autosave()}
    end)
  end

  def handle_event("element:nudge", %{"id" => id_param, "dx" => dx, "dy" => dy}, socket) do
    require_edit(socket, fn ->
      id = if id_param == "__selected__", do: socket.assigns.selected_id, else: id_param

      case id do
        nil ->
          {:noreply, socket}

        "el-" <> _ ->
          canvas = Canvas.move_element(socket.assigns.canvas, id, dx / 1.0, dy / 1.0)
          {:noreply, push_canvas(socket, canvas) |> schedule_autosave()}

        _ ->
          {:noreply, socket}
      end
    end)
  end

  def handle_event("toggle_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, mode: String.to_existing_atom(mode), connect_from: nil)}
  end

  def handle_event("set_place_type", %{"type" => type}, socket) do
    {:noreply, assign(socket, place_type: String.to_existing_atom(type))}
  end

  def handle_event("toggle_grid", _params, socket) do
    canvas = %{socket.assigns.canvas | grid_visible: !socket.assigns.canvas.grid_visible}
    {:noreply, update_canvas(socket, canvas)}
  end

  def handle_event("toggle_snap", _params, socket) do
    canvas = %{socket.assigns.canvas | snap_to_grid: !socket.assigns.canvas.snap_to_grid}
    {:noreply, update_canvas(socket, canvas)}
  end

  def handle_event("send_to_back", _params, socket) do
    require_edit(socket, fn ->
      case socket.assigns.selected_id do
        "el-" <> _ = id ->
          min_z =
            socket.assigns.canvas.elements |> Map.values() |> Enum.map(& &1.z_index) |> Enum.min()

          canvas = Canvas.update_element(socket.assigns.canvas, id, %{z_index: min_z - 1})
          {:noreply, push_canvas(socket, canvas) |> schedule_autosave()}

        _ ->
          {:noreply, socket}
      end
    end)
  end

  def handle_event("bring_to_front", _params, socket) do
    require_edit(socket, fn ->
      case socket.assigns.selected_id do
        "el-" <> _ = id ->
          max_z =
            socket.assigns.canvas.elements |> Map.values() |> Enum.map(& &1.z_index) |> Enum.max()

          canvas = Canvas.update_element(socket.assigns.canvas, id, %{z_index: max_z + 1})
          {:noreply, push_canvas(socket, canvas) |> schedule_autosave()}

        _ ->
          {:noreply, socket}
      end
    end)
  end

  def handle_event("delete_selected", _params, socket) do
    require_edit(socket, fn ->
      case socket.assigns.selected_id do
        nil ->
          {:noreply, socket}

        "conn-" <> _ = id ->
          canvas = Canvas.remove_connection(socket.assigns.canvas, id)

          {:noreply,
           push_canvas(socket, canvas) |> assign(selected_id: nil) |> schedule_autosave()}

        "el-" <> _ = id ->
          canvas = Canvas.remove_element(socket.assigns.canvas, id)

          {:noreply,
           push_canvas(socket, canvas) |> assign(selected_id: nil) |> schedule_autosave()}
      end
    end)
  end

  def handle_event("canvas:deselect", _params, socket) do
    {:noreply, assign(socket, selected_id: nil, connect_from: nil)}
  end

  def handle_event("toggle_share", _params, socket) do
    {:noreply, assign(socket, show_share: !socket.assigns.show_share)}
  end

  def handle_event("close_share", _params, socket) do
    {:noreply, assign(socket, show_share: false)}
  end

  def handle_event("canvas:undo", _params, socket) do
    require_edit(socket, fn ->
      history = History.undo(socket.assigns.history)
      {:noreply, assign(socket, history: history, canvas: history.present, selected_id: nil)}
    end)
  end

  def handle_event("canvas:redo", _params, socket) do
    require_edit(socket, fn ->
      history = History.redo(socket.assigns.history)
      {:noreply, assign(socket, history: history, canvas: history.present, selected_id: nil)}
    end)
  end

  # Properties panel updates

  def handle_event("property:update_element", %{"element_id" => id} = params, socket) do
    require_edit(socket, fn ->
      attrs =
        %{}
        |> maybe_put(:label, params["label"])
        |> maybe_put(:color, params["color"])
        |> maybe_put_float(:x, params["x"])
        |> maybe_put_float(:y, params["y"])
        |> maybe_put_float(:width, params["width"])
        |> maybe_put_float(:height, params["height"])
        |> maybe_put_atom(:type, params["type"])

      canvas = Canvas.update_element(socket.assigns.canvas, id, attrs)
      {:noreply, push_canvas(socket, canvas) |> schedule_autosave()}
    end)
  end

  def handle_event("property:update_meta", %{"element_id" => id} = params, socket) do
    require_edit(socket, fn ->
      meta_fields = Element.meta_fields(socket.assigns.canvas.elements[id].type)

      new_meta =
        Enum.reduce(meta_fields, socket.assigns.canvas.elements[id].meta, fn field, meta ->
          case params[field] do
            nil -> meta
            "" -> Map.delete(meta, field)
            val -> Map.put(meta, field, val)
          end
        end)

      canvas = Canvas.update_element(socket.assigns.canvas, id, %{meta: new_meta})
      {:noreply, push_canvas(socket, canvas) |> schedule_autosave()}
    end)
  end

  def handle_event("property:update_connection", %{"conn_id" => id} = params, socket) do
    require_edit(socket, fn ->
      attrs =
        %{}
        |> maybe_put(:label, params["label"])
        |> maybe_put(:color, params["color"])
        |> maybe_put_atom(:style, params["style"])

      canvas = Canvas.update_connection(socket.assigns.canvas, id, attrs)
      {:noreply, push_canvas(socket, canvas) |> schedule_autosave()}
    end)
  end

  # Save/Load

  def handle_event("canvas:save", _params, socket) do
    require_edit(socket, fn ->
      data = Serializer.encode(socket.assigns.canvas)

      case Canvases.update_canvas_data(socket.assigns.canvas_id, data) do
        {:ok, _} ->
          {:noreply, put_flash(socket, :info, "Canvas saved")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to save canvas")}
      end
    end)
  end

  def handle_event("canvas:load", _params, socket) do
    case Canvases.get_canvas(socket.assigns.canvas_id) do
      {:ok, record} ->
        case Serializer.decode(record.data) do
          {:ok, canvas} ->
            history = History.new(canvas)

            socket =
              assign(socket, history: history, canvas: canvas, selected_id: nil)
              |> register_elements()

            {:noreply, socket}

          {:error, _} ->
            {:noreply, socket}
        end

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  # --- Timeline event handlers ---

  def handle_event("timeline:enter", _params, socket) do
    case StatusManager.time_range() do
      :empty ->
        {:noreply, socket}

      {start_time, _end_time} = range ->
        statuses = StatusManager.statuses_at(start_time)
        canvas = apply_statuses(socket.assigns.canvas, statuses)

        {:noreply,
         socket
         |> update_canvas(canvas)
         |> assign(
           timeline_mode: :historical,
           timeline_time: start_time,
           timeline_range: range
         )
         |> fill_graph_data_at(start_time)}
    end
  end

  def handle_event("timeline:go_live", _params, socket) do
    {:noreply,
     socket
     |> stop_playback()
     |> assign(
       timeline_mode: :live,
       timeline_time: nil,
       timeline_range: nil
     )}
  end

  def handle_event("timeline:scrub", %{"time" => time_ms_str}, socket) do
    time_ms =
      case time_ms_str do
        val when is_binary(val) ->
          {ms, _} = Integer.parse(val)
          ms

        val when is_number(val) ->
          round(val)
      end

    time = DateTime.from_unix!(time_ms, :millisecond)
    statuses = StatusManager.statuses_at(time)
    canvas = apply_statuses(socket.assigns.canvas, statuses)

    {:noreply,
     socket
     |> update_canvas(canvas)
     |> assign(timeline_time: time)
     |> fill_graph_data_at(time)}
  end

  def handle_event("timeline:play_pause", _params, socket) do
    if socket.assigns.timeline_mode != :historical do
      {:noreply, socket}
    else
      if socket.assigns.timeline_playing do
        {:noreply, stop_playback(socket)}
      else
        {:noreply, start_playback(socket)}
      end
    end
  end

  def handle_event("timeline:set_speed", %{"speed" => speed_str}, socket) do
    speed =
      case Float.parse(speed_str) do
        {f, _} -> f
        :error -> 1.0
      end

    {:noreply, assign(socket, timeline_speed: speed)}
  end

  # --- Info handlers ---

  @impl true
  def handle_info({:element_status, element_id, status}, socket) do
    # Only apply live status updates when in live mode
    if socket.assigns.timeline_mode == :live do
      canvas = Canvas.set_element_status(socket.assigns.canvas, element_id, status)
      {:noreply, update_canvas(socket, canvas)}
    else
      # Manager still records events; we just don't display them
      {:noreply, socket}
    end
  end

  def handle_info({:element_metric, element_id, _metric_name, value, timestamp}, socket) do
    if socket.assigns.timeline_mode == :live do
      graph_data = socket.assigns.graph_data
      points = Map.get(graph_data, element_id, [])
      points = Enum.take([{timestamp, value} | points], @max_graph_points)
      graph_data = Map.put(graph_data, element_id, points)
      {:noreply, assign(socket, graph_data: graph_data)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:timeline_tick, socket) do
    if socket.assigns.timeline_mode != :historical or not socket.assigns.timeline_playing do
      {:noreply, assign(socket, playback_ref: nil)}
    else
      advance_ms = round(@tick_interval * socket.assigns.timeline_speed)
      current_ms = DateTime.to_unix(socket.assigns.timeline_time, :millisecond)
      new_ms = current_ms + advance_ms

      {_start, end_time} = socket.assigns.timeline_range
      end_ms = DateTime.to_unix(end_time, :millisecond)

      if new_ms >= end_ms do
        # Reached end of range
        statuses = StatusManager.statuses_at(end_time)
        canvas = apply_statuses(socket.assigns.canvas, statuses)

        {:noreply,
         socket
         |> stop_playback()
         |> update_canvas(canvas)
         |> assign(timeline_time: end_time)
         |> fill_graph_data_at(end_time)}
      else
        new_time = DateTime.from_unix!(new_ms, :millisecond)
        statuses = StatusManager.statuses_at(new_time)
        canvas = apply_statuses(socket.assigns.canvas, statuses)
        ref = Process.send_after(self(), :timeline_tick, @tick_interval)

        {:noreply,
         socket
         |> update_canvas(canvas)
         |> assign(timeline_time: new_time, playback_ref: ref)
         |> fill_graph_data_at(new_time)}
      end
    end
  end

  def handle_info(:autosave, socket) do
    if socket.assigns.can_edit do
      data = Serializer.encode(socket.assigns.canvas)
      Canvases.update_canvas_data(socket.assigns.canvas_id, data)
    end

    {:noreply, socket}
  end

  # --- Guards ---

  defp require_edit(socket, fun) do
    if socket.assigns.can_edit do
      fun.()
    else
      {:noreply, socket}
    end
  end

  # --- Private helpers ---

  defp sorted_elements(elements) do
    elements |> Map.values() |> Enum.sort_by(&{&1.z_index, &1.id})
  end

  defp graph_points_for(%{type: :graph} = element, graph_data) do
    case Map.get(graph_data, element.id) do
      nil ->
        ""

      [] ->
        ""

      points ->
        # Points are stored newest-first; reverse for left-to-right rendering
        points = Enum.reverse(points)
        count = length(points)

        {min_val, max_val} =
          Enum.min_max_by(points, &elem(&1, 1))
          |> then(fn {min, max} -> {elem(min, 1), elem(max, 1)} end)

        val_range = max(max_val - min_val, 0.1)
        padding = 14

        points
        |> Enum.with_index()
        |> Enum.map(fn {{_ts, val}, i} ->
          x = element.x + i / max(count - 1, 1) * element.width

          y =
            element.y + padding +
              (1 - (val - min_val) / val_range) * (element.height - padding - 2)

          "#{Float.round(x, 1)},#{Float.round(y, 1)}"
        end)
        |> Enum.join(" ")
    end
  end

  defp graph_points_for(_element, _graph_data), do: ""

  defp graph_value_for(%{type: :graph} = element, graph_data) do
    case Map.get(graph_data, element.id) do
      [{_ts, val} | _] -> :erlang.float_to_binary(val / 1.0, decimals: 1)
      _ -> nil
    end
  end

  defp graph_value_for(_element, _graph_data), do: nil

  defp fill_graph_data_at(socket, time) do
    graph_elements =
      socket.assigns.canvas.elements
      |> Enum.filter(fn {_id, el} -> el.type == :graph end)

    graph_data =
      Enum.reduce(graph_elements, socket.assigns.graph_data, fn {id, element}, acc ->
        metric_name = Map.get(element.meta, "metric_name", "default")

        points =
          Enum.map(0..(@max_graph_points - 1), fn i ->
            point_time = DateTime.add(time, -i * 2, :second)
            ts = DateTime.to_unix(point_time, :millisecond)

            case StatusManager.metric_at(id, metric_name, point_time) do
              {:ok, val} -> {ts, val}
              :no_data -> {ts, 0.0}
            end
          end)

        Map.put(acc, id, points)
      end)

    assign(socket, graph_data: graph_data)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp maybe_put_float(map, _key, nil), do: map
  defp maybe_put_float(map, _key, ""), do: map

  defp maybe_put_float(map, key, val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> Map.put(map, key, f)
      :error -> map
    end
  end

  defp maybe_put_float(map, key, val) when is_number(val) do
    Map.put(map, key, val / 1.0)
  end

  defp maybe_put_atom(map, _key, nil), do: map
  defp maybe_put_atom(map, _key, ""), do: map

  defp maybe_put_atom(map, key, val) when is_binary(val) do
    Map.put(map, key, String.to_existing_atom(val))
  end
end
