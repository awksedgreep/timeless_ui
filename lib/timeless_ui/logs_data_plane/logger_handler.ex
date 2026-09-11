defmodule TimelessUI.LogsDataPlane.LoggerHandler do
  @moduledoc false

  @handler_id :timeless_logs_data_plane
  @maximum_message_chars 8_192
  @maximum_metadata_entries 64
  @maximum_metadata_depth 5

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
  end

  defp format_message({:string, message}),
    do: message |> IO.chardata_to_string() |> bounded_string()

  defp format_message({:report, report}),
    do: inspect(report, limit: @maximum_metadata_entries, printable_limit: @maximum_message_chars)

  defp format_message({format, args}),
    do: format |> :io_lib.format(args) |> IO.chardata_to_string() |> bounded_string()

  defp extract_metadata(metadata) do
    metadata
    |> Map.drop([:time, :gl, :pid, :mfa, :file, :line, :domain, :report_cb])
    |> Enum.take(@maximum_metadata_entries)
    |> Map.new(fn {key, value} ->
      {to_string(key), json_value(value, @maximum_metadata_depth)}
    end)
  end

  defp json_value(value, _depth)
       when is_binary(value) or is_boolean(value) or is_number(value) or is_nil(value),
       do: if(is_binary(value), do: bounded_string(value), else: value)

  defp json_value(value, _depth) when is_atom(value), do: Atom.to_string(value)
  defp json_value(value, 0), do: inspect(value, limit: 10, printable_limit: 256)

  defp json_value(value, depth) when is_map(value) do
    value
    |> Enum.take(@maximum_metadata_entries)
    |> Map.new(fn {key, nested} -> {to_string(key), json_value(nested, depth - 1)} end)
  end

  defp json_value(value, depth) when is_list(value),
    do: value |> Enum.take(@maximum_metadata_entries) |> Enum.map(&json_value(&1, depth - 1))

  defp json_value(value, depth) when is_tuple(value),
    do: value |> Tuple.to_list() |> json_value(depth)

  defp json_value(value, _depth), do: inspect(value, limit: 10, printable_limit: 256)

  defp bounded_string(value), do: String.slice(value, 0, @maximum_message_chars)
end
