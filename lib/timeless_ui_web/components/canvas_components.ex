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
  attr :stream_entries, :list, default: []

  def canvas_element(assigns) do
    assigns = assign(assigns, status_color: status_color(assigns.element.status))

    ~H"""
    <g
      class={"canvas-element#{if @selected, do: " canvas-element--selected", else: ""}"}
      data-element-id={@element.id}
    >
      <.element_body
        element={@element}
        graph_points={@graph_points}
        graph_value={@graph_value}
        stream_entries={@stream_entries}
      />
      <.element_icon element={@element} />
      <text
        :if={@element.type not in [:graph, :log_stream, :trace_stream]}
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
      pointer-events="none"
    />
    <%!-- Transparent hit rect covering full cylinder for drag/click --%>
    <rect
      x={@element.x}
      y={@element.y}
      width={@element.width}
      height={@element.height}
      fill="transparent"
      class="canvas-element__hit"
    />
    """
  end

  defp element_body(%{element: %{type: :log_stream}} = assigns) do
    level_filter = Map.get(assigns.element.meta, "level", "all")

    log_title =
      case assigns.element.label do
        nil -> "Logs"
        "" -> "Logs"
        label -> "#{label} | #{level_filter}"
      end

    rows = Enum.take(assigns.stream_entries, 4)

    assigns = assign(assigns, log_title: log_title, rows: rows)

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
    <clipPath id={"log-clip-#{@element.id}"}>
      <rect x={@element.x} y={@element.y} width={@element.width} height={@element.height} rx="4" />
    </clipPath>
    <text
      x={@element.x + 4}
      y={@element.y + 10}
      fill="#94a3b8"
      font-size="8"
      clip-path={"url(#log-clip-#{@element.id})"}
    >
      {@log_title}
    </text>
    <text
      :for={{entry, i} <- Enum.with_index(@rows)}
      x={@element.x + 4}
      y={@element.y + 24 + i * 14}
      fill={log_level_color(entry.level)}
      font-size="9"
      font-family="monospace"
      clip-path={"url(#log-clip-#{@element.id})"}
    >
      {format_log_entry(entry)}
    </text>
    <text
      :if={@rows == []}
      x={@element.x + @element.width / 2}
      y={@element.y + @element.height / 2 + 4}
      text-anchor="middle"
      fill="#475569"
      font-size="9"
    >
      Waiting for logs...
    </text>
    """
  end

  defp element_body(%{element: %{type: :trace_stream}} = assigns) do
    service_filter = Map.get(assigns.element.meta, "service", "all")

    trace_title =
      case assigns.element.label do
        nil -> "Traces"
        "" -> "Traces"
        label -> "#{label} | #{service_filter}"
      end

    rows = Enum.take(assigns.stream_entries, 4)

    assigns = assign(assigns, trace_title: trace_title, rows: rows)

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
    <clipPath id={"trace-clip-#{@element.id}"}>
      <rect
        x={@element.x}
        y={@element.y}
        width={@element.width}
        height={@element.height}
        rx="4"
      />
    </clipPath>
    <text
      x={@element.x + 4}
      y={@element.y + 10}
      fill="#94a3b8"
      font-size="8"
      clip-path={"url(#trace-clip-#{@element.id})"}
    >
      {@trace_title}
    </text>
    <text
      :for={{span, i} <- Enum.with_index(@rows)}
      x={@element.x + 4}
      y={@element.y + 24 + i * 14}
      font-size="9"
      font-family="monospace"
      clip-path={"url(#trace-clip-#{@element.id})"}
    >
      <tspan fill="#e2e8f0">{span.name}</tspan>
      <tspan dx="6" fill={duration_color(span.duration_ns)}>
        {format_duration(span.duration_ns)}
      </tspan>
      <tspan dx="6" fill={span_status_color(span.status)}>{span_status_label(span.status)}</tspan>
    </text>
    <text
      :if={@rows == []}
      x={@element.x + @element.width / 2}
      y={@element.y + @element.height / 2 + 4}
      text-anchor="middle"
      fill="#475569"
      font-size="9"
    >
      Waiting for traces...
    </text>
    """
  end

  defp element_body(%{element: %{type: :graph}} = assigns) do
    metric_name = Map.get(assigns.element.meta, "metric_name", "metric")

    graph_title =
      case assigns.element.label do
        nil -> metric_name
        "" -> metric_name
        label -> "#{label} | #{metric_name}"
      end

    assigns = assign(assigns, graph_title: graph_title)

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
    <clipPath id={"graph-clip-#{@element.id}"}>
      <rect x={@element.x} y={@element.y} width={@element.width} height={@element.height} />
    </clipPath>
    <text
      x={@element.x + 4}
      y={@element.y + 10}
      class="canvas-graph__title"
      fill="#94a3b8"
      font-size="8"
      clip-path={"url(#graph-clip-#{@element.id})"}
    >
      {@graph_title}
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
    assigns = assign(assigns, image_url: assigns.element.meta["image_url"])

    ~H"""
    <rect
      x={@element.x}
      y={@element.y}
      width={@element.width}
      height={@element.height}
      rx="6"
      ry="6"
      fill={if @image_url && @image_url != "", do: "none", else: @element.color}
      class="canvas-element__body"
    />
    <image
      :if={@image_url && @image_url != ""}
      x={@element.x}
      y={@element.y}
      width={@element.width}
      height={@element.height}
      href={@image_url}
      preserveAspectRatio="xMidYMid slice"
      clip-path={"url(#rect-clip-#{@element.id})"}
    />
    <clipPath :if={@image_url && @image_url != ""} id={"rect-clip-#{@element.id}"}>
      <rect
        x={@element.x}
        y={@element.y}
        width={@element.width}
        height={@element.height}
        rx="6"
        ry="6"
      />
    </clipPath>
    """
  end

  # --- Element icons (rendered above label) ---

  defp element_icon(%{element: %{type: :rect}} = assigns), do: ~H""
  defp element_icon(%{element: %{type: :database}} = assigns), do: ~H""
  defp element_icon(%{element: %{type: :graph}} = assigns), do: ~H""

  defp element_icon(%{element: %{type: :log_stream}} = assigns) do
    assigns =
      assign(assigns,
        cx: assigns.element.x + assigns.element.width / 2,
        cy: assigns.element.y + assigns.element.height / 2 - 8
      )

    ~H"""
    <g
      class="canvas-element__icon"
      transform={"translate(#{@cx}, #{@cy}) scale(1.2) translate(-8, -8)"}
    >
      <line x1="2" y1="3" x2="14" y2="3" stroke="#334155" stroke-width="1.5" opacity="0.6" />
      <line x1="2" y1="7" x2="12" y2="7" stroke="#334155" stroke-width="1.5" opacity="0.6" />
      <line x1="2" y1="11" x2="10" y2="11" stroke="#334155" stroke-width="1.5" opacity="0.6" />
      <line x1="2" y1="15" x2="13" y2="15" stroke="#334155" stroke-width="1.5" opacity="0.6" />
    </g>
    """
  end

  defp element_icon(%{element: %{type: :trace_stream}} = assigns) do
    assigns =
      assign(assigns,
        cx: assigns.element.x + assigns.element.width / 2,
        cy: assigns.element.y + assigns.element.height / 2 - 8
      )

    ~H"""
    <g
      class="canvas-element__icon"
      transform={"translate(#{@cx}, #{@cy}) scale(1.2) translate(-8, -8)"}
    >
      <rect x="0" y="1" width="14" height="3" rx="1" fill="#334155" opacity="0.6" />
      <rect x="3" y="6" width="10" height="3" rx="1" fill="#334155" opacity="0.5" />
      <rect x="6" y="11" width="8" height="3" rx="1" fill="#334155" opacity="0.4" />
    </g>
    """
  end

  defp element_icon(%{element: %{type: :server}} = assigns) do
    # Rack lines + power dot
    assigns =
      assign(assigns,
        cx: assigns.element.x + assigns.element.width / 2,
        cy: assigns.element.y + assigns.element.height / 2 - 10
      )

    ~H"""
    <g
      class="canvas-element__icon"
      transform={"translate(#{@cx}, #{@cy}) scale(1.4) translate(-12, -12)"}
    >
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
    <g
      class="canvas-element__icon"
      transform={"translate(#{@cx}, #{@cy}) scale(1.4) translate(-10, -10)"}
    >
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
    <g
      class="canvas-element__icon"
      transform={"translate(#{@cx}, #{@cy}) scale(1.4) translate(-10, -8)"}
    >
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
    <g
      class="canvas-element__icon"
      transform={"translate(#{@cx}, #{@cy}) scale(1.4) translate(-7, -10)"}
    >
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
    <g
      class="canvas-element__icon"
      transform={"translate(#{@cx}, #{@cy}) scale(1.4) translate(-10, -10)"}
    >
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

  defp element_icon(%{element: %{type: :router}} = assigns) do
    # Circle with 4 directional arrows — 40x40 icon
    assigns =
      assign(assigns,
        cx: assigns.element.x + assigns.element.width / 2,
        cy: assigns.element.y + assigns.element.height / 2 - 10
      )

    ~H"""
    <g class="canvas-element__icon" transform={"translate(#{@cx - 20}, #{@cy - 20})"}>
      <circle cx="20" cy="20" r="8" fill="none" stroke="white" stroke-width="2.5" opacity="0.9" />
      <line x1="20" y1="0" x2="20" y2="12" stroke="white" stroke-width="2.5" opacity="0.9" />
      <polygon points="14,6 20,0 26,6" fill="white" opacity="0.9" />
      <line x1="20" y1="28" x2="20" y2="40" stroke="white" stroke-width="2.5" opacity="0.9" />
      <polygon points="14,34 20,40 26,34" fill="white" opacity="0.9" />
      <line x1="0" y1="20" x2="12" y2="20" stroke="white" stroke-width="2.5" opacity="0.9" />
      <polygon points="6,14 0,20 6,26" fill="white" opacity="0.9" />
      <line x1="28" y1="20" x2="40" y2="20" stroke="white" stroke-width="2.5" opacity="0.9" />
      <polygon points="34,14 40,20 34,26" fill="white" opacity="0.9" />
    </g>
    """
  end

  defp element_icon(%{element: %{type: :canvas}} = assigns) do
    # Stacked rectangles icon representing sub-canvas
    assigns =
      assign(assigns,
        cx: assigns.element.x + assigns.element.width / 2,
        cy: assigns.element.y + assigns.element.height / 2 - 10
      )

    ~H"""
    <g
      class="canvas-element__icon"
      transform={"translate(#{@cx}, #{@cy}) scale(1.4) translate(-10, -10)"}
    >
      <rect
        x="4"
        y="0"
        width="16"
        height="12"
        rx="1.5"
        fill="none"
        stroke="white"
        stroke-width="1.2"
        opacity="0.5"
      />
      <rect
        x="2"
        y="3"
        width="16"
        height="12"
        rx="1.5"
        fill="none"
        stroke="white"
        stroke-width="1.2"
        opacity="0.7"
      />
      <rect
        x="0"
        y="6"
        width="16"
        height="12"
        rx="1.5"
        fill="none"
        stroke="white"
        stroke-width="1.2"
        opacity="0.9"
      />
      <line x1="3" y1="10" x2="10" y2="10" stroke="white" stroke-width="0.8" opacity="0.5" />
      <line x1="3" y1="13" x2="8" y2="13" stroke="white" stroke-width="0.8" opacity="0.5" />
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

  # --- Log/Trace stream helpers ---

  defp log_level_color(:error), do: "#ef4444"
  defp log_level_color(:warning), do: "#f59e0b"
  defp log_level_color(:info), do: "#22c55e"
  defp log_level_color(:debug), do: "#94a3b8"
  defp log_level_color(_), do: "#94a3b8"

  defp format_log_entry(entry) do
    ts =
      case entry.timestamp do
        ts when is_integer(ts) ->
          ts |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%H:%M:%S")

        _ ->
          "??:??:??"
      end

    level = entry.level |> to_string() |> String.upcase() |> String.slice(0, 4)
    "#{ts} [#{level}] #{entry.message}"
  end

  defp duration_color(nil), do: "#94a3b8"

  defp duration_color(duration_ns) when is_integer(duration_ns) do
    ms = duration_ns / 1_000_000

    cond do
      ms < 100 -> "#22c55e"
      ms < 500 -> "#f59e0b"
      true -> "#ef4444"
    end
  end

  defp duration_color(_), do: "#94a3b8"

  defp format_duration(nil), do: "?ms"

  defp format_duration(duration_ns) when is_integer(duration_ns) do
    ms = duration_ns / 1_000_000

    cond do
      ms < 1 -> "#{Float.round(ms, 2)}ms"
      ms < 1000 -> "#{Float.round(ms, 1)}ms"
      true -> "#{Float.round(ms / 1000, 1)}s"
    end
  end

  defp format_duration(_), do: "?ms"

  defp span_status_color(:ok), do: "#22c55e"
  defp span_status_color(:error), do: "#ef4444"
  defp span_status_color(_), do: "#94a3b8"

  defp span_status_label(:ok), do: "OK"
  defp span_status_label(:error), do: "ERR"
  defp span_status_label(_), do: "---"

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
