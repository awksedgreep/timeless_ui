defmodule TimelessUIWeb.CanvasLive do
  use TimelessUIWeb, :live_view

  alias TimelessUI.Canvas
  alias TimelessUI.Canvas.{ViewBox, History, Element, Connection, Serializer}
  alias TimelessUI.Canvases
  alias TimelessUI.Canvases.Policy
  alias TimelessUI.DataSource.Manager, as: StatusManager
  alias TimelessUI.StreamManager
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
    graph: "Graph",
    log_stream: "Logs",
    trace_stream: "Traces",
    canvas: "Canvas",
    text: "Text"
  }

  # @tick_interval removed — playback no longer used

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
        Phoenix.PubSub.subscribe(TimelessUI.PubSub, StreamManager.topic())
      end

      canvas =
        case Serializer.decode(record.data) do
          {:ok, c} -> c
          {:error, _} -> Canvas.new()
        end

      history = History.new(canvas)

      stream_data =
        if connected?(socket) and map_size(canvas.elements) > 0 do
          StatusManager.register_elements(Map.values(canvas.elements))
          register_stream_elements(canvas.elements)
        else
          %{}
        end

      breadcrumbs = Canvases.breadcrumb_chain(canvas_id)

      {:ok,
       assign(socket,
         history: history,
         canvas: canvas,
         selected_ids: MapSet.new(),
         mode: :select,
         place_type: :rect,
         connect_from: nil,
         canvas_name: record.name,
         canvas_id: canvas_id,
         user_id: current_user.id,
         can_edit: can_edit,
         is_owner: is_owner,
         show_share: false,
         renaming: false,
         page_title: record.name,
         breadcrumbs: breadcrumbs,
         # Timeline assigns
         timeline_mode: :live,
         timeline_time: nil,
         timeline_span: 300,
         timeline_data_range: nil,
         graph_data: %{},
         stream_data: stream_data,
         clipboard: [],
         paste_offset: 20
       )
       |> refresh_data_range()
       |> fill_graph_data_at(DateTime.utc_now())
       |> push_density_update()}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Canvas not found or access denied")
         |> redirect(to: ~p"/canvases")}
    end
  end

  @max_graph_points 60
  @max_stream_entries 50

  @impl true
  def render(assigns) do
    assigns = assign(assigns, type_labels: @type_labels)

    ~H"""
    <div class={"canvas-container#{if sole_selected_object(@selected_ids, @canvas) != nil, do: " canvas-container--panel-open", else: ""}"}>
      <div class="canvas-toolbar">
        <span class="canvas-toolbar__logo" title="Timeless">
          <svg
            width="28"
            height="16"
            viewBox="0 0 28 16"
            fill="none"
            xmlns="http://www.w3.org/2000/svg"
          >
            <path
              d="M8 2C4.5 2 2 4.7 2 8s2.5 6 6 6c2.2 0 4-1.2 5.5-3L14 10.5l.5.5c1.5 1.8 3.3 3 5.5 3 3.5 0 6-2.7 6-6s-2.5-6-6-6c-2.2 0-4 1.2-5.5 3L14 5.5 13.5 5C12 3.2 10.2 2 8 2z"
              stroke="#6366f1"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
          </svg>
        </span>
        <span class="canvas-toolbar__sep"></span>
        <span :if={length(@breadcrumbs) > 1} class="canvas-breadcrumbs">
          <span :for={{crumb, i} <- Enum.with_index(Enum.drop(@breadcrumbs, -1))}>
            <span :if={i > 0} class="canvas-breadcrumbs__sep">/</span>
            <.link
              navigate={~p"/canvas/#{elem(crumb, 0)}"}
              class="canvas-breadcrumbs__link"
            >
              {elem(crumb, 1)}
            </.link>
          </span>
          <span class="canvas-breadcrumbs__sep">/</span>
        </span>
        <form
          :if={@renaming}
          phx-submit="save_name"
          phx-click-away="cancel_rename"
          class="canvas-toolbar__name-form"
        >
          <input
            type="text"
            name="name"
            value={@canvas_name}
            class="canvas-toolbar__name-input"
            autofocus
            phx-key="Escape"
            phx-keydown="cancel_rename"
          />
        </form>
        <span
          :if={!@renaming}
          class={"canvas-toolbar__name#{if @is_owner, do: " canvas-toolbar__name--editable", else: ""}"}
          phx-click={if @is_owner, do: "start_rename"}
        >
          {@canvas_name}
        </span>
        <span class="canvas-toolbar__sep"></span>
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
          disabled={!@can_edit || MapSet.size(@selected_ids) == 0}
        >
          Back
        </button>
        <button
          phx-click="bring_to_front"
          class="canvas-toolbar__btn"
          disabled={!@can_edit || MapSet.size(@selected_ids) == 0}
        >
          Front
        </button>
        <button
          phx-click="delete_selected"
          class="canvas-toolbar__btn canvas-toolbar__btn--danger"
          disabled={!@can_edit || MapSet.size(@selected_ids) == 0}
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
          selected={conn.id in @selected_ids}
        />

        <.canvas_element
          :for={element <- sorted_elements(@canvas.elements)}
          :key={element.id}
          element={element}
          selected={element.id in @selected_ids}
          graph_points={graph_points_for(element, @graph_data)}
          graph_value={graph_value_for(element, @graph_data)}
          stream_entries={stream_entries_for(element, @stream_data)}
        />
      </svg>

      <.properties_panel
        selected={sole_selected_object(@selected_ids, @canvas)}
        canvas={@canvas}
      />

      <.timeline_bar
        timeline_mode={@timeline_mode}
        timeline_time={@timeline_time}
        timeline_span={@timeline_span}
        timeline_data_range={@timeline_data_range}
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

  defp sole_selected_object(selected_ids, canvas) do
    case MapSet.to_list(selected_ids) do
      [id] -> find_object(id, canvas)
      _ -> nil
    end
  end

  defp find_object("el-" <> _ = id, canvas), do: Map.get(canvas.elements, id)
  defp find_object("conn-" <> _ = id, canvas), do: Map.get(canvas.connections, id)
  defp find_object(_id, _canvas), do: nil

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

          # For canvas elements, atomically create the child canvas first
          meta =
            if type == :canvas do
              case Canvases.create_child_canvas(
                     socket.assigns.canvas_id,
                     "Sub-canvas #{socket.assigns.canvas.next_id}"
                   ) do
                {:ok, child} -> %{"canvas_id" => to_string(child.id)}
                {:error, _} -> %{}
              end
            else
              %{}
            end

          {canvas, el} =
            Canvas.add_element(socket.assigns.canvas, %{
              type: type,
              x: x / 1.0,
              y: y / 1.0,
              color: defaults.color,
              width: defaults.width,
              height: defaults.height,
              label: "#{@type_labels[type] || type} #{socket.assigns.canvas.next_id}",
              meta: meta
            })

          maybe_register_stream(el)

          {:noreply, push_canvas(socket, canvas) |> schedule_autosave()}
        end)

      :connect ->
        {:noreply, assign(socket, connect_from: nil)}

      :select ->
        {:noreply, assign(socket, selected_ids: MapSet.new())}
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
        {:noreply, assign(socket, selected_ids: MapSet.new([id]))}
    end
  end

  def handle_event("element:dblclick", %{"id" => id}, socket) do
    case Map.get(socket.assigns.canvas.elements, id) do
      %{type: :canvas, meta: %{"canvas_id" => canvas_id}} when canvas_id != "" ->
        {:noreply, push_navigate(socket, to: ~p"/canvas/#{canvas_id}")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("element:shift_select", %{"id" => id}, socket) do
    selected_ids = socket.assigns.selected_ids

    selected_ids =
      if MapSet.member?(selected_ids, id),
        do: MapSet.delete(selected_ids, id),
        else: MapSet.put(selected_ids, id)

    {:noreply, assign(socket, selected_ids: selected_ids)}
  end

  def handle_event("marquee:select", %{"ids" => ids}, socket) do
    {:noreply, assign(socket, selected_ids: MapSet.new(ids))}
  end

  def handle_event("connection:select", %{"id" => id}, socket) do
    {:noreply, assign(socket, selected_ids: MapSet.new([id]))}
  end

  def handle_event("element:move", %{"id" => id, "dx" => dx, "dy" => dy}, socket) do
    require_edit(socket, fn ->
      selected_ids = socket.assigns.selected_ids

      canvas =
        if MapSet.member?(selected_ids, id) and MapSet.size(selected_ids) > 1 do
          Canvas.move_elements(
            socket.assigns.canvas,
            MapSet.to_list(selected_ids),
            dx / 1.0,
            dy / 1.0
          )
        else
          Canvas.move_element(socket.assigns.canvas, id, dx / 1.0, dy / 1.0)
        end

      {:noreply, push_canvas(socket, canvas) |> schedule_autosave()}
    end)
  end

  def handle_event("element:resize", %{"id" => id, "width" => width, "height" => height}, socket) do
    require_edit(socket, fn ->
      canvas = Canvas.resize_element(socket.assigns.canvas, id, width / 1.0, height / 1.0)
      {:noreply, push_canvas(socket, canvas) |> schedule_autosave()}
    end)
  end

  def handle_event("element:nudge", %{"dx" => dx, "dy" => dy}, socket) do
    require_edit(socket, fn ->
      selected_ids = socket.assigns.selected_ids
      element_ids = Enum.filter(selected_ids, &String.starts_with?(&1, "el-"))

      case element_ids do
        [] ->
          {:noreply, socket}

        ids ->
          canvas = Canvas.move_elements(socket.assigns.canvas, ids, dx / 1.0, dy / 1.0)
          {:noreply, push_canvas(socket, canvas) |> schedule_autosave()}
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
      element_ids =
        socket.assigns.selected_ids
        |> Enum.filter(&String.starts_with?(&1, "el-"))

      case element_ids do
        [] ->
          {:noreply, socket}

        ids ->
          min_z =
            socket.assigns.canvas.elements |> Map.values() |> Enum.map(& &1.z_index) |> Enum.min()

          canvas =
            Enum.with_index(ids)
            |> Enum.reduce(socket.assigns.canvas, fn {id, i}, acc ->
              Canvas.update_element(acc, id, %{z_index: min_z - length(ids) + i})
            end)

          {:noreply, push_canvas(socket, canvas) |> schedule_autosave()}
      end
    end)
  end

  def handle_event("bring_to_front", _params, socket) do
    require_edit(socket, fn ->
      element_ids =
        socket.assigns.selected_ids
        |> Enum.filter(&String.starts_with?(&1, "el-"))

      case element_ids do
        [] ->
          {:noreply, socket}

        ids ->
          max_z =
            socket.assigns.canvas.elements |> Map.values() |> Enum.map(& &1.z_index) |> Enum.max()

          canvas =
            Enum.with_index(ids)
            |> Enum.reduce(socket.assigns.canvas, fn {id, i}, acc ->
              Canvas.update_element(acc, id, %{z_index: max_z + 1 + i})
            end)

          {:noreply, push_canvas(socket, canvas) |> schedule_autosave()}
      end
    end)
  end

  def handle_event("delete_selected", _params, socket) do
    require_edit(socket, fn ->
      selected_ids = socket.assigns.selected_ids

      if MapSet.size(selected_ids) == 0 do
        {:noreply, socket}
      else
        # Unregister streams for elements being deleted
        for id <- selected_ids, String.starts_with?(id, "el-") do
          el = socket.assigns.canvas.elements[id]

          if el && el.type in [:log_stream, :trace_stream] do
            StreamManager.unregister_stream(id)
          end
        end

        # Remove connections first, then elements
        conn_ids = Enum.filter(selected_ids, &String.starts_with?(&1, "conn-"))
        element_ids = Enum.filter(selected_ids, &String.starts_with?(&1, "el-"))

        canvas =
          Enum.reduce(conn_ids, socket.assigns.canvas, fn id, acc ->
            Canvas.remove_connection(acc, id)
          end)

        canvas = Canvas.remove_elements(canvas, element_ids)

        {:noreply,
         push_canvas(socket, canvas)
         |> assign(selected_ids: MapSet.new())
         |> schedule_autosave()}
      end
    end)
  end

  def handle_event("canvas:deselect", _params, socket) do
    {:noreply, assign(socket, selected_ids: MapSet.new(), connect_from: nil)}
  end

  def handle_event("select_all", _params, socket) do
    all_ids = socket.assigns.canvas.elements |> Map.keys() |> MapSet.new()
    {:noreply, assign(socket, selected_ids: all_ids)}
  end

  def handle_event("canvas:copy", _params, socket) do
    element_ids =
      socket.assigns.selected_ids
      |> Enum.filter(&String.starts_with?(&1, "el-"))

    templates =
      Enum.map(element_ids, &Map.get(socket.assigns.canvas.elements, &1))
      |> Enum.reject(&is_nil/1)

    {:noreply, assign(socket, clipboard: templates, paste_offset: 20)}
  end

  def handle_event("canvas:cut", _params, socket) do
    require_edit(socket, fn ->
      element_ids =
        socket.assigns.selected_ids
        |> Enum.filter(&String.starts_with?(&1, "el-"))

      templates =
        Enum.map(element_ids, &Map.get(socket.assigns.canvas.elements, &1))
        |> Enum.reject(&is_nil/1)

      canvas = Canvas.remove_elements(socket.assigns.canvas, element_ids)

      {:noreply,
       push_canvas(socket, canvas)
       |> assign(clipboard: templates, paste_offset: 20, selected_ids: MapSet.new())
       |> schedule_autosave()}
    end)
  end

  def handle_event("canvas:paste", _params, socket) do
    require_edit(socket, fn ->
      case socket.assigns.clipboard do
        [] ->
          {:noreply, socket}

        templates ->
          offset = socket.assigns.paste_offset

          {canvas, new_ids} =
            Canvas.duplicate_elements(socket.assigns.canvas, templates, offset)

          {:noreply,
           push_canvas(socket, canvas)
           |> assign(
             selected_ids: MapSet.new(new_ids),
             paste_offset: offset + 20
           )
           |> schedule_autosave()}
      end
    end)
  end

  def handle_event("start_rename", _params, socket) do
    {:noreply, assign(socket, renaming: true)}
  end

  def handle_event("cancel_rename", _params, socket) do
    {:noreply, assign(socket, renaming: false)}
  end

  def handle_event("save_name", %{"name" => name}, socket) do
    name = String.trim(name)

    if name == "" do
      {:noreply, assign(socket, renaming: false)}
    else
      case Canvases.rename_canvas(socket.assigns.canvas_id, socket.assigns.user_id, name) do
        {:ok, _} ->
          breadcrumbs = Canvases.breadcrumb_chain(socket.assigns.canvas_id)

          {:noreply,
           assign(socket,
             canvas_name: name,
             renaming: false,
             page_title: name,
             breadcrumbs: breadcrumbs
           )}

        {:error, _} ->
          {:noreply,
           socket
           |> put_flash(:error, "Could not rename canvas")
           |> assign(renaming: false)}
      end
    end
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

      {:noreply,
       assign(socket, history: history, canvas: history.present, selected_ids: MapSet.new())}
    end)
  end

  def handle_event("canvas:redo", _params, socket) do
    require_edit(socket, fn ->
      history = History.redo(socket.assigns.history)

      {:noreply,
       assign(socket, history: history, canvas: history.present, selected_ids: MapSet.new())}
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

      # Re-register stream with new filter opts when meta changes
      el = canvas.elements[id]

      case el.type do
        :log_stream ->
          StreamManager.register_log_stream(id, build_log_opts(new_meta))

        :trace_stream ->
          StreamManager.register_trace_stream(id, build_trace_opts(new_meta))

        _ ->
          :ok
      end

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
              assign(socket, history: history, canvas: canvas, selected_ids: MapSet.new())
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

  def handle_event("timeline:go_live", _params, socket) do
    {:noreply,
     socket
     |> assign(timeline_mode: :live, timeline_time: nil)
     |> refresh_data_range()
     |> fill_graph_data_at(DateTime.utc_now())
     |> push_slider_update()
     |> push_density_update()}
  end

  def handle_event("timeline:change", %{"time" => center_ms}, socket)
      when is_number(center_ms) do
    # Slider value is window center; convert back to window end for internal state
    half_span = div(socket.assigns.timeline_span * 1000, 2)
    time = DateTime.from_unix!(round(center_ms) + half_span, :millisecond)
    statuses = StatusManager.statuses_at(time)
    canvas = apply_statuses(socket.assigns.canvas, statuses)

    {:noreply,
     socket
     |> update_canvas(canvas)
     |> assign(timeline_mode: :historical, timeline_time: time)
     |> fill_graph_data_at(time)
     |> fill_stream_data_at(time)}
  end

  def handle_event("timeline:change", %{"_target" => ["span"]} = params, socket) do
    span =
      case Integer.parse(params["span"] || "") do
        {s, _} -> s
        :error -> 300
      end

    socket = assign(socket, timeline_span: span)
    time = socket.assigns.timeline_time || DateTime.utc_now()

    {:noreply,
     socket
     |> fill_graph_data_at(time)
     |> fill_stream_data_at(time)
     |> push_slider_update()}
  end

  def handle_event("timeline:change", _params, socket) do
    {:noreply, socket}
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

  def handle_info({:stream_entry, element_id, entry_map}, socket) do
    if socket.assigns.timeline_mode == :live do
      stream_data = socket.assigns.stream_data
      entries = Map.get(stream_data, element_id, [])
      entries = Enum.take([entry_map | entries], @max_stream_entries)
      stream_data = Map.put(stream_data, element_id, entries)
      {:noreply, assign(socket, stream_data: stream_data)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:stream_span, element_id, span_map}, socket) do
    if socket.assigns.timeline_mode == :live do
      stream_data = socket.assigns.stream_data
      entries = Map.get(stream_data, element_id, [])
      entries = Enum.take([span_map | entries], @max_stream_entries)
      stream_data = Map.put(stream_data, element_id, entries)
      {:noreply, assign(socket, stream_data: stream_data)}
    else
      {:noreply, socket}
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

    span = socket.assigns.timeline_span
    from = DateTime.add(time, -span, :second)

    graph_data =
      Enum.reduce(graph_elements, socket.assigns.graph_data, fn {id, element}, acc ->
        metric_name = Map.get(element.meta, "metric_name", "default")

        points =
          case StatusManager.metric_range(id, metric_name, from, time) do
            {:ok, pts} when pts != [] ->
              downsample(pts, @max_graph_points)

            _ ->
              []
          end

        Map.put(acc, id, points)
      end)

    assign(socket, graph_data: graph_data)
  end

  # Downsample a list of points to at most max_count, evenly spaced.
  # Returns newest-first (reversed) for the graph renderer.
  defp downsample(points, max_count) when length(points) <= max_count do
    Enum.reverse(points)
  end

  defp downsample(points, max_count) do
    total = length(points)
    step = total / max_count

    0..(max_count - 1)
    |> Enum.map(fn i -> Enum.at(points, round(i * step)) end)
    |> Enum.reverse()
  end

  defp fill_stream_data_at(socket, time) do
    span = socket.assigns.timeline_span
    from = DateTime.add(time, -span, :second)
    backends = Application.get_env(:timeless_ui, :stream_backends, [])

    stream_elements =
      socket.assigns.canvas.elements
      |> Enum.filter(fn {_id, el} -> el.type in [:log_stream, :trace_stream] end)

    stream_data =
      Enum.reduce(stream_elements, socket.assigns.stream_data, fn {id, element}, acc ->
        entries = query_stream_historical(element, from, time, backends)
        Map.put(acc, id, entries)
      end)

    assign(socket, stream_data: stream_data)
  end

  defp query_stream_historical(%{type: :log_stream} = element, from, to, backends) do
    case Keyword.get(backends, :log) do
      nil ->
        []

      backend ->
        filters =
          build_log_opts(element.meta)
          |> Keyword.put(:since, from)
          |> Keyword.put(:until, to)
          |> Keyword.put(:limit, @max_stream_entries)
          |> Keyword.put(:order, :desc)

        case backend.query(filters) do
          {:ok, %{entries: entries}} ->
            Enum.map(entries, fn e ->
              %{
                timestamp: e.timestamp,
                level: e.level,
                message: e.message,
                metadata: e.metadata
              }
            end)

          _ ->
            []
        end
    end
  end

  defp query_stream_historical(%{type: :trace_stream} = element, from, to, backends) do
    case Keyword.get(backends, :trace) do
      nil ->
        []

      backend ->
        filters =
          build_trace_opts(element.meta)
          |> Keyword.put(:since, from)
          |> Keyword.put(:until, to)
          |> Keyword.put(:limit, @max_stream_entries)
          |> Keyword.put(:order, :desc)

        case backend.query(filters) do
          {:ok, %{entries: spans}} ->
            Enum.map(spans, fn s ->
              %{
                trace_id: s.trace_id,
                span_id: s.span_id,
                name: s.name,
                kind: s.kind,
                duration_ns: s.duration_ns,
                status: s.status,
                status_message: s.status_message,
                service: get_span_service(s)
              }
            end)

          _ ->
            []
        end
    end
  end

  defp query_stream_historical(_element, _from, _to, _backends), do: []

  defp get_span_service(span) do
    cond do
      is_map(span.attributes) && Map.has_key?(span.attributes, "service.name") ->
        span.attributes["service.name"]

      is_map(span.resource) && Map.has_key?(span.resource, "service.name") ->
        span.resource["service.name"]

      true ->
        nil
    end
  end

  defp refresh_data_range(socket) do
    case StatusManager.time_range() do
      :empty -> assign(socket, timeline_data_range: nil)
      range -> assign(socket, timeline_data_range: range)
    end
  end

  defp push_slider_update(socket) do
    now_ms = System.system_time(:millisecond)
    span_ms = socket.assigns.timeline_span * 1000
    half_span = div(span_ms, 2)

    {data_start_ms, data_end_ms} =
      case socket.assigns.timeline_data_range do
        {s, e} -> {DateTime.to_unix(s, :millisecond), DateTime.to_unix(e, :millisecond)}
        _ -> {now_ms - 86_400_000, now_ms}
      end

    slider_min = data_start_ms + half_span
    slider_max = max(data_end_ms - half_span, slider_min + 60_000)

    window_end_ms =
      case socket.assigns.timeline_time do
        nil -> now_ms
        %DateTime{} = t -> DateTime.to_unix(t, :millisecond)
      end

    value = min(window_end_ms - half_span, slider_max)
    window_ratio = min(span_ms / max(slider_max - slider_min, 1), 1.0)
    is_live = socket.assigns.timeline_time == nil

    push_event(socket, "update-slider", %{
      min: slider_min,
      max: slider_max,
      value: value,
      windowRatio: window_ratio,
      live: is_live
    })
  end

  defp push_density_update(socket) do
    case socket.assigns.timeline_data_range do
      {data_start, data_end} ->
        buckets = StatusManager.data_density(data_start, data_end, 80)
        push_event(socket, "update-density", %{buckets: buckets})

      _ ->
        push_event(socket, "update-density", %{buckets: []})
    end
  end

  defp stream_entries_for(%{type: type} = element, stream_data)
       when type in [:log_stream, :trace_stream] do
    max_rows = max(floor((element.height - 24) / 14), 1)
    Enum.take(Map.get(stream_data, element.id, []), max_rows)
  end

  defp stream_entries_for(_element, _stream_data), do: []

  defp register_stream_elements(elements) do
    Enum.reduce(elements, %{}, fn {_id, el}, acc ->
      case el.type do
        :log_stream ->
          opts = build_log_opts(el.meta)
          StreamManager.register_log_stream(el.id, opts)
          Map.put(acc, el.id, StreamManager.get_buffer(el.id))

        :trace_stream ->
          opts = build_trace_opts(el.meta)
          StreamManager.register_trace_stream(el.id, opts)
          Map.put(acc, el.id, StreamManager.get_buffer(el.id))

        _ ->
          acc
      end
    end)
  end

  defp maybe_register_stream(%{type: :log_stream} = el) do
    StreamManager.register_log_stream(el.id, build_log_opts(el.meta))
  end

  defp maybe_register_stream(%{type: :trace_stream} = el) do
    StreamManager.register_trace_stream(el.id, build_trace_opts(el.meta))
  end

  defp maybe_register_stream(_el), do: :ok

  defp build_log_opts(meta) do
    opts = []

    opts =
      case Map.get(meta, "level") do
        nil -> opts
        "" -> opts
        level -> Keyword.put(opts, :level, String.to_existing_atom(level))
      end

    case Map.get(meta, "metadata_filter") do
      nil ->
        opts

      "" ->
        opts

      filter_str ->
        metadata =
          filter_str
          |> String.split(",")
          |> Enum.reduce(%{}, fn pair, acc ->
            case String.split(String.trim(pair), "=", parts: 2) do
              [k, v] -> Map.put(acc, String.trim(k), String.trim(v))
              _ -> acc
            end
          end)

        if map_size(metadata) > 0, do: Keyword.put(opts, :metadata, metadata), else: opts
    end
  end

  defp build_trace_opts(meta) do
    opts = []

    opts =
      case Map.get(meta, "service") do
        nil -> opts
        "" -> opts
        svc -> Keyword.put(opts, :service, svc)
      end

    opts =
      case Map.get(meta, "name") do
        nil -> opts
        "" -> opts
        name -> Keyword.put(opts, :name, name)
      end

    case Map.get(meta, "kind") do
      nil -> opts
      "" -> opts
      kind -> Keyword.put(opts, :kind, String.to_existing_atom(kind))
    end
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
