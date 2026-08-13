defmodule TimelessUI.LogsDataPlane.Client do
  @moduledoc """
  Complete-operation HTTP adapter for the Rust logs data plane.

  It owns no SQLite connection and rejects filter shapes outside the declared
  Rust API instead of crossing back to `TimelessLogs`.
  """

  alias TimelessUI.LogsDataPlane.Process, as: DataPlaneProcess

  @default_timeout 30_000
  @levels ~w(debug info notice warning error critical alert emergency)
  @level_atoms %{
    "debug" => :debug,
    "info" => :info,
    "notice" => :notice,
    "warning" => :warning,
    "error" => :error,
    "critical" => :critical,
    "alert" => :alert,
    "emergency" => :emergency
  }
  @query_keys ~w(level message service host path status start end limit offset order)a

  def health(opts \\ []), do: json_request(:get, "/health", opts)

  @doc """
  Live tail: streams entries matching one LogsQL filter expression from
  `/select/logsql/tail`, sending `{:timeless_logs, :entry, entry}` messages
  to `subscriber` — the same message shape the embedded engine's Registry
  tail delivers, so consumers cannot tell the sources apart. Returns
  `{:ok, pid}`; kill the pid to unsubscribe (the closed connection
  unsubscribes server-side).
  """
  def tail(query, subscriber, opts \\ [])
      when is_binary(query) and is_pid(subscriber) and is_list(opts) do
    with {:ok, endpoint, owner_header} <- resolve_connection(opts) do
      parent = subscriber

      {:ok, pid} =
        Task.start(fn ->
          Req.request(
            method: :get,
            url: endpoint <> "/select/logsql/tail",
            params: %{query: query},
            headers: request_headers(opts, owner_header),
            receive_timeout: :infinity,
            retry: false,
            decode_body: false,
            into: fn {:data, chunk}, {req, resp} ->
              if resp.status == 200 do
                buffer = Process.get(:tail_buffer, "") <> chunk
                {lines, rest} = split_complete_lines(buffer)
                Process.put(:tail_buffer, rest)
                Enum.each(lines, fn line ->
                  case Jason.decode(line) do
                    {:ok, row} when is_map(row) ->
                      send(parent, {:timeless_logs, :entry, tail_entry(row)})

                    _ ->
                      :ok
                  end
                end)
              end

              {:cont, {req, resp}}
            end
          )
        end)

      {:ok, pid}
    end
  end

  defp split_complete_lines(buffer) do
    parts = String.split(buffer, "\n")
    {complete, [rest]} = Enum.split(parts, length(parts) - 1)
    {Enum.reject(complete, &(&1 == "")), rest}
  end

  defp tail_entry(row) do
    {timestamp, row} = Map.pop(row, "_time")
    {message, row} = Map.pop(row, "_msg", "")
    {level, metadata} = Map.pop(row, "level", "info")

    timestamp =
      case is_binary(timestamp) && DateTime.from_iso8601(timestamp) do
        {:ok, datetime, _offset} -> datetime
        _ -> timestamp
      end

    %{timestamp: timestamp, level: level, message: message, metadata: metadata}
  end
  def stats(opts \\ []), do: json_request(:get, "/select/logsql/stats", opts)
  def flush(opts \\ []), do: json_request(:get, "/api/v1/flush", opts)

  def backup(destination, opts \\ []) when is_binary(destination) do
    json_request(
      :post,
      "/api/v1/backup",
      json_body(opts, %{"destination" => destination})
    )
  end

  def ingest(entries, opts \\ []) when is_list(entries) do
    with {:ok, body} <- encode_entries(entries),
         {:ok, status, response} <-
           raw_request(
             :post,
             "/insert/jsonline",
             opts
             |> Keyword.put(:body, body)
             |> Keyword.put(:headers, [{"content-type", "application/x-ndjson"}])
           ) do
      case {status, response} do
        {204, ""} -> {:ok, length(entries)}
        {200, body} -> decode_ingest_result(body, length(entries))
        _ -> {:error, {:unexpected_response, status, excerpt(response)}}
      end
    end
  end

  def query(filters, opts \\ []) when is_list(filters) do
    with :ok <- validate_query_filters(filters),
         limit when is_integer(limit) and limit > 0 <- Keyword.get(filters, :limit, 100),
         request_limit = min(limit + 1, 100_000),
         params <- filters |> Keyword.put(:limit, request_limit) |> Map.new(),
         {:ok, 200, body} <-
           raw_request(:get, "/select/logsql/query", Keyword.put(opts, :params, params)),
         {:ok, entries} <- decode_entries(body) do
      has_more = length(entries) > limit
      entries = Enum.take(entries, limit)

      {:ok,
       %{
         entries: entries,
         total: Keyword.get(filters, :offset, 0) + length(entries) + if(has_more, do: 1, else: 0),
         limit: limit,
         offset: Keyword.get(filters, :offset, 0),
         has_more: has_more
       }}
    else
      {:ok, status, body} -> {:error, {:unexpected_response, status, excerpt(body)}}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_query_limit}
    end
  end

  def field_values(field, filters \\ [], opts \\ [])

  def field_values(field, filters, opts)
      when field in ["service", "host", "path", "status"] and is_list(filters) do
    with :ok <- validate_query_filters(filters),
         params <- filters |> Keyword.put(:field, field) |> Map.new(),
         {:ok, body} <-
           json_request(:get, "/select/logsql/field_values", Keyword.put(opts, :params, params)),
         %{"values" => values} when is_list(values) <- body,
         true <- Enum.all?(values, &is_binary/1) do
      {:ok, Enum.map(values, &%{"value" => &1})}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_field_values_response}
    end
  end

  def field_values(field, _filters, _opts),
    do: {:error, {:unsupported_capability, :log_field_values, field}}

  def query_logsql(query, opts \\ []) when is_binary(query) do
    raw_request(
      :post,
      "/select/logsql/query",
      opts
      |> Keyword.put(:body, URI.encode_query(%{"query" => query}))
      |> Keyword.put(:headers, [{"content-type", "application/x-www-form-urlencoded"}])
    )
  end

  defp validate_query_filters(filters) do
    unknown = Keyword.keys(filters) -- @query_keys

    cond do
      unknown != [] -> {:error, {:unsupported_capability, :logs_query_filters, unknown}}
      level = Keyword.get(filters, :level) -> validate_level(level)
      true -> :ok
    end
  end

  defp json_body(opts, value) do
    opts
    |> Keyword.put(:body, Jason.encode!(value))
    |> Keyword.update(:headers, [{"content-type", "application/json"}], fn headers ->
      [{"content-type", "application/json"} | headers]
    end)
  end

  defp validate_level(level) when is_atom(level), do: validate_level(Atom.to_string(level))
  defp validate_level(level) when level in @levels, do: :ok
  defp validate_level(level), do: {:error, {:unsupported_capability, :log_level, level}}

  defp encode_entries(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, lines} ->
      case encode_entry(entry) do
        {:ok, line} -> {:cont, {:ok, [line | lines]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, lines} -> {:ok, lines |> Enum.reverse() |> Enum.join("\n") |> Kernel.<>("\n")}
      {:error, _reason} = error -> error
    end
  end

  defp encode_entry(%{timestamp: timestamp, level: level, message: message} = entry)
       when is_integer(timestamp) and is_binary(message) do
    metadata = Map.get(entry, :metadata, %{})

    if is_map(metadata) do
      object =
        metadata
        |> stringify_keys()
        |> Map.merge(%{
          "_time" => timestamp,
          "_msg" => message,
          "level" => if(is_atom(level), do: Atom.to_string(level), else: level)
        })

      case Jason.encode(object) do
        {:ok, line} -> {:ok, line}
        {:error, error} -> {:error, {:invalid_log_entry, error}}
      end
    else
      {:error, {:invalid_log_entry, :metadata}}
    end
  end

  defp encode_entry(entry), do: {:error, {:invalid_log_entry, entry}}

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp decode_ingest_result(body, expected) do
    with {:ok, %{"entries" => entries, "errors" => 0}}
         when is_integer(entries) and entries == expected <- Jason.decode(body) do
      {:ok, entries}
    else
      {:ok, decoded} -> {:error, {:partial_ingest, decoded}}
      {:error, error} -> {:error, {:invalid_response, error}}
    end
  end

  defp decode_entries(""), do: {:ok, []}

  defp decode_entries(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, entries} ->
      with {:ok, object} when is_map(object) <- Jason.decode(line),
           {:ok, entry} <- decode_entry(object) do
        {:cont, {:ok, [entry | entries]}}
      else
        error -> {:halt, {:error, {:invalid_response, error}}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_entry(%{"_time" => timestamp, "_msg" => message, "level" => level} = object)
       when is_binary(timestamp) and is_binary(message) and level in @levels do
    with {:ok, datetime, 0} <- DateTime.from_iso8601(timestamp) do
      {:ok,
       %{
         timestamp: DateTime.to_unix(datetime, :microsecond),
         level: Map.fetch!(@level_atoms, level),
         message: message,
         metadata: Map.drop(object, ["_time", "_msg", "level"])
       }}
    else
      _ -> {:error, :invalid_timestamp}
    end
  end

  defp decode_entry(_object), do: {:error, :invalid_log_entry_shape}

  defp json_request(method, path, opts) do
    with {:ok, status, body} when status in 200..299 <- raw_request(method, path, opts),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    else
      {:ok, status, body} -> {:error, {:unexpected_response, status, excerpt(body)}}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_response, error}}
      {:error, _reason} = error -> error
    end
  end

  defp raw_request(method, path, opts) do
    with {:ok, endpoint, owner_header} <- resolve_connection(opts) do
      request_options = [
        method: method,
        url: endpoint <> path,
        params: Keyword.get(opts, :params, %{}),
        headers: request_headers(opts, owner_header),
        receive_timeout: Keyword.get(opts, :timeout, @default_timeout),
        retry: false,
        decode_body: false
      ]

      request_options =
        case Keyword.fetch(opts, :body) do
          {:ok, body} -> Keyword.put(request_options, :body, body)
          :error -> request_options
        end

      request = Keyword.get(opts, :request, &Req.request/1)

      case request.(request_options) do
        {:ok, %{status: status, body: body}} when is_integer(status) and is_binary(body) ->
          {:ok, status, body}

        {:ok, %{status: status, body: body}} ->
          {:error, {:invalid_response_body, status, body}}

        {:error, reason} ->
          {:error, {:transport, reason}}
      end
    end
  rescue
    error -> {:error, {:transport, error}}
  catch
    :exit, reason -> {:error, {:transport, reason}}
  end

  defp resolve_connection(opts) do
    case Keyword.fetch(opts, :base_url) do
      {:ok, endpoint} when is_binary(endpoint) ->
        with {:ok, endpoint} <- loopback_endpoint(endpoint), do: {:ok, endpoint, nil}

      _ ->
        process = Keyword.get(opts, :process, DataPlaneProcess)
        timeout = Keyword.get(opts, :timeout, @default_timeout)

        with {:ok, endpoint} <- DataPlaneProcess.await_ready(process, timeout),
             {:ok, endpoint} <- loopback_endpoint(endpoint),
             {:ok, header} <- DataPlaneProcess.authorization_header(process) do
          {:ok, endpoint, header}
        end
    end
  end

  defp request_headers(opts, nil), do: Keyword.get(opts, :headers, [])

  defp request_headers(opts, {name, value}) do
    [{name, value} | Enum.reject(Keyword.get(opts, :headers, []), &authorization_header?/1)]
  end

  defp authorization_header?({name, _value}),
    do: String.downcase(to_string(name)) == "authorization"

  defp loopback_endpoint(endpoint) do
    uri = URI.parse(endpoint)

    with "http" <- uri.scheme,
         host when is_binary(host) <- uri.host,
         {:ok, address} <- :inet.parse_address(String.to_charlist(host)),
         true <- match?({127, _, _, _}, address),
         true <- uri.userinfo == nil and uri.query == nil and uri.fragment == nil,
         true <- uri.path in [nil, "", "/"] do
      {:ok, String.trim_trailing(endpoint, "/")}
    else
      _ -> {:error, {:logs_data_plane_must_use_loopback, endpoint}}
    end
  end

  defp excerpt(body) when is_binary(body), do: binary_part(body, 0, min(byte_size(body), 1_024))
end
