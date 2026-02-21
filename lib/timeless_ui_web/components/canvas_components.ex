defmodule TimelessUIWeb.CanvasComponents do
  @moduledoc """
  SVG element and connection renderers for the canvas.
  """
  use Phoenix.Component

  alias TimelessUI.Canvas.Element

  attr :element, Element, required: true
  attr :selected, :boolean, default: false
  attr :graph_points, :string, default: ""
  attr :graph_value, :string, default: nil

  def canvas_element(assigns) do
    assigns = assign(assigns, status_color: status_color(assigns.element.status))

    ~H"""
    <g
      class={"canvas-element#{if @selected, do: " canvas-element--selected", else: ""}"}
      data-element-id={@element.id}
    >
      <.element_body element={@element} graph_points={@graph_points} graph_value={@graph_value} />
      <.element_icon element={@element} />
      <text
        :if={@element.type != :graph}
        x={@element.x + @element.width / 2}
        y={@element.y + @element.height - 16}
        text-anchor="middle"
        dominant-baseline="central"
        class="canvas-element__label"
      >
        {@element.label}
      </text>
      <circle
        cx={@element.x + @element.width - 8}
        cy={@element.y + 8}
        r="5"
        fill={@status_color}
        class={"canvas-element__status#{if @element.status == :error, do: " canvas-element__status--error", else: ""}"}
      />
      <rect
        :if={@selected}
        x={@element.x + @element.width - 10}
        y={@element.y + @element.height - 10}
        width="10"
        height="10"
        class="canvas-element__handle"
        data-handle="se"
      />
    </g>
    """
  end

  defp status_color(:ok), do: "#22c55e"
  defp status_color(:warning), do: "#f59e0b"
  defp status_color(:error), do: "#ef4444"
  defp status_color(_), do: "#64748b"

  # --- Element body shapes ---

  defp element_body(%{element: %{type: :database}} = assigns) do
    ~H"""
    <ellipse
      cx={@element.x + @element.width / 2}
      cy={@element.y + 15}
      rx={@element.width / 2}
      ry="15"
      fill={@element.color}
      class="canvas-element__body"
    />
    <rect
      x={@element.x}
      y={@element.y + 15}
      width={@element.width}
      height={@element.height - 30}
      fill={@element.color}
      class="canvas-element__body-rect"
    />
    <ellipse
      cx={@element.x + @element.width / 2}
      cy={@element.y + @element.height - 15}
      rx={@element.width / 2}
      ry="15"
      fill={@element.color}
      class="canvas-element__body-bottom"
    />
    <ellipse
      cx={@element.x + @element.width / 2}
      cy={@element.y + @element.height - 15}
      rx={@element.width / 2}
      ry="15"
      fill="none"
      stroke={@element.color}
      stroke-width="1"
      style="filter: brightness(0.7)"
    />
    """
  end

  defp element_body(%{element: %{type: :graph}} = assigns) do
    assigns =
      assign(assigns,
        metric_name: Map.get(assigns.element.meta, "metric_name", "metric")
      )

    ~H"""
    <rect
      x={@element.x}
      y={@element.y}
      width={@element.width}
      height={@element.height}
      rx="4"
      ry="4"
      fill="#0f172a"
      class="canvas-element__body"
    />
    <polyline
      :if={@graph_points != ""}
      points={@graph_points}
      fill="none"
      stroke={@element.color}
      stroke-width="1.5"
      stroke-linejoin="round"
      stroke-linecap="round"
      class="canvas-graph__line"
    />
    <text
      x={@element.x + 4}
      y={@element.y + 10}
      class="canvas-graph__title"
      fill="#94a3b8"
      font-size="8"
    >
      {@metric_name}
    </text>
    <text
      :if={@graph_value}
      x={@element.x + @element.width - 4}
      y={@element.y + 10}
      text-anchor="end"
      class="canvas-graph__title"
      fill={@element.color}
      font-size="8"
    >
      {@graph_value}
    </text>
    """
  end

  defp element_body(assigns) do
    ~H"""
    <rect
      x={@element.x}
      y={@element.y}
      width={@element.width}
      height={@element.height}
      rx="6"
      ry="6"
      fill={@element.color}
      class="canvas-element__body"
    />
    """
  end

  # --- Element icons (rendered above label) ---

  defp element_icon(%{element: %{type: :rect}} = assigns), do: ~H""
  defp element_icon(%{element: %{type: :database}} = assigns), do: ~H""
  defp element_icon(%{element: %{type: :graph}} = assigns), do: ~H""

  defp element_icon(%{element: %{type: :server}} = assigns) do
    # Rack lines + power dot
    assigns =
      assign(assigns,
        cx: assigns.element.x + assigns.element.width / 2,
        cy: assigns.element.y + assigns.element.height / 2 - 10
      )

    ~H"""
    <g class="canvas-element__icon" transform={"translate(#{@cx - 12}, #{@cy - 12})"}>
      <rect
        x="0"
        y="0"
        width="24"
        height="7"
        rx="1"
        fill="none"
        stroke="white"
        stroke-width="1.2"
        opacity="0.9"
      />
      <rect
        x="0"
        y="9"
        width="24"
        height="7"
        rx="1"
        fill="none"
        stroke="white"
        stroke-width="1.2"
        opacity="0.9"
      />
      <rect
        x="0"
        y="18"
        width="24"
        height="7"
        rx="1"
        fill="none"
        stroke="white"
        stroke-width="1.2"
        opacity="0.9"
      />
      <circle cx="20" cy="3.5" r="1.5" fill="#22c55e" />
      <circle cx="20" cy="12.5" r="1.5" fill="#22c55e" />
      <circle cx="20" cy="21.5" r="1.5" fill="#22c55e" />
    </g>
    """
  end

  defp element_icon(%{element: %{type: :service}} = assigns) do
    # Gear/cog
    assigns =
      assign(assigns,
        cx: assigns.element.x + assigns.element.width / 2,
        cy: assigns.element.y + assigns.element.height / 2 - 8
      )

    ~H"""
    <g class="canvas-element__icon" transform={"translate(#{@cx - 10}, #{@cy - 10})"}>
      <path
        d="M10 3.5L11.5 1h-3L10 3.5zM10 16.5L8.5 19h3L10 16.5zM3.5 10L1 8.5v3L3.5 10zM16.5 10L19 11.5v-3L16.5 10zM4.5 5.5L2.5 3.5l-1 1L4.5 7.5 4.5 5.5zM15.5 14.5L17.5 16.5l1-1L15.5 12.5V14.5zM5.5 15.5L3.5 17.5l1 1L7.5 15.5H5.5zM14.5 4.5L16.5 2.5l-1-1L12.5 4.5H14.5z"
        fill="white"
        opacity="0.9"
      />
      <circle cx="10" cy="10" r="4" fill="none" stroke="white" stroke-width="1.5" opacity="0.9" />
    </g>
    """
  end

  defp element_icon(%{element: %{type: :load_balancer}} = assigns) do
    # Branching arrows
    assigns =
      assign(assigns,
        cx: assigns.element.x + assigns.element.width / 2,
        cy: assigns.element.y + assigns.element.height / 2 - 8
      )

    ~H"""
    <g class="canvas-element__icon" transform={"translate(#{@cx - 12}, #{@cy - 8})"}>
      <path
        d="M0 8 L8 8 L8 2 L16 2 M8 8 L8 8 L16 8 M8 8 L8 14 L16 14"
        fill="none"
        stroke="white"
        stroke-width="1.5"
        stroke-linecap="round"
        opacity="0.9"
      />
      <polygon points="16,0 20,2 16,4" fill="white" opacity="0.9" />
      <polygon points="16,6 20,8 16,10" fill="white" opacity="0.9" />
      <polygon points="16,12 20,14 16,16" fill="white" opacity="0.9" />
    </g>
    """
  end

  defp element_icon(%{element: %{type: :queue}} = assigns) do
    # Pipeline dividers
    assigns =
      assign(assigns,
        cx: assigns.element.x + assigns.element.width / 2,
        cy: assigns.element.y + assigns.element.height / 2 - 8
      )

    ~H"""
    <g class="canvas-element__icon" transform={"translate(#{@cx - 14}, #{@cy - 6})"}>
      <rect
        x="0"
        y="0"
        width="28"
        height="12"
        rx="2"
        fill="none"
        stroke="white"
        stroke-width="1.2"
        opacity="0.9"
      />
      <line x1="7" y1="0" x2="7" y2="12" stroke="white" stroke-width="1" opacity="0.6" />
      <line x1="14" y1="0" x2="14" y2="12" stroke="white" stroke-width="1" opacity="0.6" />
      <line x1="21" y1="0" x2="21" y2="12" stroke="white" stroke-width="1" opacity="0.6" />
      <polygon points="-2,6 -6,3 -6,9" fill="white" opacity="0.7" />
      <polygon points="30,6 34,3 34,9" fill="white" opacity="0.7" />
    </g>
    """
  end

  defp element_icon(%{element: %{type: :cache}} = assigns) do
    # Lightning bolt
    assigns =
      assign(assigns,
        cx: assigns.element.x + assigns.element.width / 2,
        cy: assigns.element.y + assigns.element.height / 2 - 8
      )

    ~H"""
    <g class="canvas-element__icon" transform={"translate(#{@cx - 7}, #{@cy - 10})"}>
      <polygon points="8,0 2,10 7,10 5,20 13,8 8,8" fill="white" opacity="0.9" />
    </g>
    """
  end

  defp element_icon(%{element: %{type: :network}} = assigns) do
    # Globe/mesh
    assigns =
      assign(assigns,
        cx: assigns.element.x + assigns.element.width / 2,
        cy: assigns.element.y + assigns.element.height / 2 - 6
      )

    ~H"""
    <g class="canvas-element__icon" transform={"translate(#{@cx - 10}, #{@cy - 10})"}>
      <circle cx="10" cy="10" r="9" fill="none" stroke="white" stroke-width="1.2" opacity="0.9" />
      <ellipse
        cx="10"
        cy="10"
        rx="4"
        ry="9"
        fill="none"
        stroke="white"
        stroke-width="1"
        opacity="0.7"
      />
      <line x1="1" y1="7" x2="19" y2="7" stroke="white" stroke-width="0.8" opacity="0.6" />
      <line x1="1" y1="13" x2="19" y2="13" stroke="white" stroke-width="0.8" opacity="0.6" />
    </g>
    """
  end

  # Fallback for unknown types
  defp element_icon(assigns), do: ~H""

  # --- Connection component ---

  attr :connection, :map, required: true
  attr :source, :map, required: true
  attr :target, :map, required: true
  attr :selected, :boolean, default: false

  def canvas_connection(assigns) do
    assigns =
      assign(assigns,
        x1: assigns.source.x + assigns.source.width / 2,
        y1: assigns.source.y + assigns.source.height / 2,
        x2: assigns.target.x + assigns.target.width / 2,
        y2: assigns.target.y + assigns.target.height / 2,
        dash: dash_for_style(assigns.connection.style)
      )

    ~H"""
    <g
      class={"canvas-connection#{if @selected, do: " canvas-connection--selected", else: ""}"}
      data-connection-id={@connection.id}
    >
      <line
        x1={@x1}
        y1={@y1}
        x2={@x2}
        y2={@y2}
        stroke="transparent"
        stroke-width="12"
        class="canvas-connection__hit"
      />
      <line
        x1={@x1}
        y1={@y1}
        x2={@x2}
        y2={@y2}
        stroke={@connection.color}
        stroke-width="2"
        stroke-dasharray={@dash}
        class="canvas-connection__line"
      />
      <text
        :if={@connection.label != ""}
        x={(@x1 + @x2) / 2}
        y={(@y1 + @y2) / 2 - 8}
        text-anchor="middle"
        class="canvas-connection__label"
      >
        {@connection.label}
      </text>
    </g>
    """
  end

  defp dash_for_style(:dashed), do: "8 4"
  defp dash_for_style(:dotted), do: "3 3"
  defp dash_for_style(_), do: ""

  # --- Timeline Bar ---

  attr :timeline_mode, :atom, required: true
  attr :timeline_time, :any, default: nil
  attr :timeline_playing, :boolean, default: false
  attr :timeline_speed, :float, default: 1.0
  attr :timeline_range, :any, default: nil

  def timeline_bar(assigns) do
    assigns =
      assign(assigns,
        range_start_ms: range_start_ms(assigns.timeline_range),
        range_end_ms: range_end_ms(assigns.timeline_range),
        current_ms: time_to_ms(assigns.timeline_time),
        formatted_time: format_timeline_time(assigns.timeline_time)
      )

    ~H"""
    <div class="timeline-bar">
      <div :if={@timeline_mode == :live} class="timeline-bar__live-section">
        <button
          phx-click="timeline:enter"
          class="timeline-bar__btn"
          disabled={@timeline_range == nil and @range_start_ms == 0}
        >
          Time Travel
        </button>
        <span class="timeline-bar__status timeline-bar__status--live">LIVE</span>
      </div>

      <div :if={@timeline_mode == :historical} class="timeline-bar__historical-section">
        <button
          phx-click="timeline:go_live"
          class="timeline-bar__btn timeline-bar__btn--live"
        >
          LIVE
        </button>

        <span class="timeline-bar__sep"></span>

        <button
          phx-click="timeline:play_pause"
          class="timeline-bar__btn"
        >
          {if @timeline_playing, do: "Pause", else: "Play"}
        </button>

        <span class="timeline-bar__sep"></span>

        <select
          phx-change="timeline:set_speed"
          name="speed"
          class="timeline-bar__speed"
        >
          <option value="0.5" selected={@timeline_speed == 0.5}>0.5x</option>
          <option value="1.0" selected={@timeline_speed == 1.0}>1x</option>
          <option value="2.0" selected={@timeline_speed == 2.0}>2x</option>
          <option value="5.0" selected={@timeline_speed == 5.0}>5x</option>
          <option value="10.0" selected={@timeline_speed == 10.0}>10x</option>
        </select>

        <input
          type="range"
          min={@range_start_ms}
          max={@range_end_ms}
          value={@current_ms}
          phx-change="timeline:scrub"
          name="time"
          class="timeline-bar__slider"
        />

        <span class="timeline-bar__time">{@formatted_time}</span>
      </div>
    </div>
    """
  end

  defp range_start_ms(nil), do: 0
  defp range_start_ms({start, _end}), do: DateTime.to_unix(start, :millisecond)

  defp range_end_ms(nil), do: 0
  defp range_end_ms({_start, end_t}), do: DateTime.to_unix(end_t, :millisecond)

  defp time_to_ms(nil), do: 0
  defp time_to_ms(%DateTime{} = t), do: DateTime.to_unix(t, :millisecond)

  defp format_timeline_time(nil), do: "--:--:--"

  defp format_timeline_time(%DateTime{} = t) do
    t
    |> Calendar.strftime("%H:%M:%S")
  end
end
