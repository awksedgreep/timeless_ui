defmodule TimelessUI.Observability.LoggerPropagator do
  @moduledoc false

  require Logger

  @handler_id "timeless-ui-logger-propagator"

  def attach do
    events = [
      [:phoenix, :endpoint, :start],
      [:phoenix, :live_view, :mount, :start],
      [:phoenix, :live_view, :handle_params, :start],
      [:phoenix, :live_view, :handle_event, :start]
    ]

    :telemetry.attach_many(@handler_id, events, &__MODULE__.handle_event/4, nil)
  end

  def handle_event(_event, _measurements, _metadata, _config) do
    case OpenTelemetry.Tracer.current_span_ctx() do
      :undefined ->
        :ok

      span_ctx when is_tuple(span_ctx) ->
        OpenTelemetry.Tracer.set_attributes(TimelessUI.Observability.Identity.span_attributes())

        trace_id = OpenTelemetry.Span.hex_trace_id(span_ctx)
        span_id = OpenTelemetry.Span.hex_span_id(span_ctx)

        if is_binary(trace_id) and trace_id != "" do
          Logger.metadata(
            [trace_id: trace_id, span_id: span_id] ++
              TimelessUI.Observability.Identity.logger_metadata()
          )
        end

      _ ->
        :ok
    end
  end
end
