defmodule TimelessUI.LogsDataPlane.LoggerHandler do
  @moduledoc false

  @handler_id :timeless_logs_data_plane

  def handler_id, do: @handler_id
  def adding_handler(config), do: {:ok, config}
  def removing_handler(_config), do: :ok
  def changing_config(:set, _old, new), do: {:ok, new}
  def changing_config(:update, old, new), do: {:ok, Map.merge(old, new)}

  def log(%{level: level, msg: message, meta: metadata}, %{config: %{buffer: buffer}}) do
    entry = %{
      timestamp: Map.get(metadata, :time, System.os_time(:microsecond)),
      level: level,
      message: format_message(message),
      metadata: extract_metadata(metadata)
    }

    case TimelessUI.LogsDataPlane.Buffer.log(buffer, entry) do
      :ok ->
        :ok

      {:error, reason} ->
        :telemetry.execute(
          [:timeless_ui, :logs_data_plane, :logger, :rejected],
          %{entries: 1},
          %{reason: reason}
        )

        :ok
    end
  catch
    :exit, reason ->
      :telemetry.execute(
        [:timeless_ui, :logs_data_plane, :logger, :unavailable],
        %{entries: 1},
        %{reason: reason}
      )

      :ok
  end

  defp format_message({:string, message}), do: IO.chardata_to_string(message)
  defp format_message({:report, report}), do: inspect(report)
  defp format_message({format, args}), do: IO.chardata_to_string(:io_lib.format(format, args))

  defp extract_metadata(metadata) do
    metadata
    |> Map.drop([:time, :gl, :pid, :mfa, :file, :line, :domain, :report_cb])
    |> Map.new(fn {key, value} -> {to_string(key), json_value(value)} end)
  end

  defp json_value(value)
       when is_binary(value) or is_boolean(value) or is_number(value) or is_nil(value),
       do: value

  defp json_value(value) when is_atom(value), do: Atom.to_string(value)

  defp json_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), json_value(nested)} end)
  end

  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_value()
  defp json_value(value), do: inspect(value)
end
