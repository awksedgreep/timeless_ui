defmodule TimelessUI.TracesDataPlane.Client do
  @moduledoc """
  Complete-response adapter for the Rust traces data plane.

  Native dashboard results remain plain validated maps here so the Phoenix
  control plane does not acquire a storage-library dependency.
  """

  alias TimelessUI.TracesDataPlane.Process, as: DataPlaneProcess

  @default_timeout 30_000
  @kinds ~w(internal server client producer consumer)
  @statuses ~w(unset ok error)
  @kind_atoms %{
    "internal" => :internal,
    "server" => :server,
    "client" => :client,
    "producer" => :producer,
    "consumer" => :consumer
  }
  @status_atoms %{"unset" => :unset, "ok" => :ok, "error" => :error}

  def health(opts \\ []), do: json_request(:get, "/health", opts)
  def stats(opts \\ []), do: json_request(:get, "/select/traces/stats", opts)
  def flush(opts \\ []), do: json_request(:post, "/api/v1/flush", opts)

  def ingest_otlp(body, opts \\ []) when is_binary(body) do
    protobuf? = Keyword.get(opts, :format, :protobuf) == :protobuf
    gzip? = Keyword.get(opts, :gzip, false)

    headers =
      [
        {"content-type", if(protobuf?, do: "application/x-protobuf", else: "application/json")}
      ] ++ if(gzip?, do: [{"content-encoding", "gzip"}], else: [])

    with {:ok, status, response} <-
           raw_request(
             :post,
             "/insert/opentelemetry/v1/traces",
             opts |> Keyword.put(:body, body) |> Keyword.put(:headers, headers)
           ),
         true <- status in 200..299 || {:error, {:unexpected_response, status, excerpt(response)}},
         {:ok, decoded} <- Jason.decode(response) do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_response, error}}
      {:error, _reason} = error -> error
    end
  end

  def search(filters, opts \\ []) when is_list(filters) do
    allowed = [:name, :service, :kind, :status, :since, :until, :limit, :offset, :order]
    unknown = Keyword.keys(filters) -- allowed

    if unknown == [] do
      params = Map.new(filters, fn {key, value} -> {key, encode_param(value)} end)

      with {:ok, body} <-
             json_request(:get, "/select/timeless/api/spans", Keyword.put(opts, :params, params)),
           {:ok, result} <- decode_search(body) do
        {:ok, result}
      end
    else
      {:error, {:unsupported_capability, :traces_query_filters, unknown}}
    end
  end

  def trace(trace_id, opts \\ []) when is_binary(trace_id) do
    with true <- valid_id?(trace_id, 32) || {:error, :invalid_trace_id},
         {:ok, %{"spans" => spans}} when is_list(spans) <-
           json_request(:get, "/select/timeless/api/traces/#{trace_id}", opts),
         {:ok, spans} <- decode_spans(spans),
         true <- Enum.all?(spans, &(&1.trace_id == trace_id)) || {:error, :trace_id_mismatch} do
      {:ok, spans}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_trace_response}
    end
  end

  def jaeger_services(opts \\ []), do: json_request(:get, "/select/jaeger/api/services", opts)

  def jaeger_operations(service, opts \\ []) when is_binary(service) do
    json_request(
      :get,
      "/select/jaeger/api/services/#{URI.encode(service)}/operations",
      opts
    )
  end

  def jaeger_search(params, opts \\ []) when is_map(params) or is_list(params) do
    json_request(:get, "/select/jaeger/api/traces", Keyword.put(opts, :params, params))
  end

  def jaeger_trace(trace_id, opts \\ []) when is_binary(trace_id) do
    json_request(:get, "/select/jaeger/api/traces/#{trace_id}", opts)
  end

  defp decode_search(%{
         "entries" => entries,
         "total" => total,
         "limit" => limit,
         "offset" => offset,
         "has_more" => has_more
       })
       when is_list(entries) and is_integer(total) and total >= 0 and is_integer(limit) and
              limit > 0 and is_integer(offset) and offset >= 0 and is_boolean(has_more) do
    with true <- length(entries) <= limit || {:error, :response_exceeds_limit},
         {:ok, entries} <- decode_spans(entries) do
      {:ok,
       %{
         entries: entries,
         total: total,
         limit: limit,
         offset: offset,
         has_more: has_more
       }}
    end
  end

  defp decode_search(_body), do: {:error, :invalid_search_response}

  defp decode_spans(spans) do
    spans
    |> Enum.reduce_while({:ok, []}, fn span, {:ok, decoded} ->
      case decode_span(span) do
        {:ok, span} -> {:cont, {:ok, [span | decoded]}}
        {:error, reason} -> {:halt, {:error, {:invalid_span, reason}}}
      end
    end)
    |> case do
      {:ok, spans} -> {:ok, Enum.reverse(spans)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_span(%{
         "trace_id" => trace_id,
         "span_id" => span_id,
         "parent_span_id" => parent_span_id,
         "name" => name,
         "kind" => kind,
         "start_time" => start_time,
         "end_time" => end_time,
         "duration_ns" => duration_ns,
         "status" => status,
         "status_message" => status_message,
         "attributes" => attributes,
         "events" => events,
         "resource" => resource,
         "instrumentation_scope" => instrumentation_scope
       }) do
    with true <- valid_id?(trace_id, 32) || :trace_id,
         true <- valid_id?(span_id, 16) || :span_id,
         true <- (is_nil(parent_span_id) or valid_id?(parent_span_id, 16)) || :parent_span_id,
         true <- is_binary(name) || :name,
         true <- kind in @kinds || :kind,
         true <- status in @statuses || :status,
         true <- is_integer(start_time) || :start_time,
         true <- is_integer(end_time) || :end_time,
         true <- (is_integer(duration_ns) and duration_ns >= 0) || :duration_ns,
         true <- end_time - start_time == duration_ns || :inconsistent_duration,
         true <- (is_nil(status_message) or is_binary(status_message)) || :status_message,
         true <- is_map(attributes) || :attributes,
         true <- (is_list(events) and Enum.all?(events, &is_map/1)) || :events,
         true <- is_map(resource) || :resource,
         true <- is_map(instrumentation_scope) || :instrumentation_scope do
      {:ok,
       %{
         trace_id: trace_id,
         span_id: span_id,
         parent_span_id: parent_span_id,
         name: name,
         kind: Map.fetch!(@kind_atoms, kind),
         start_time: start_time,
         end_time: end_time,
         duration_ns: duration_ns,
         status: Map.fetch!(@status_atoms, status),
         status_message: status_message,
         attributes: attributes,
         events: events,
         resource: resource,
         instrumentation_scope: instrumentation_scope
       }}
    else
      reason -> {:error, reason}
    end
  end

  defp decode_span(_span), do: {:error, :invalid_shape}

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
      _ -> {:error, {:traces_data_plane_must_use_loopback, endpoint}}
    end
  end

  defp valid_id?(value, width) when is_binary(value) and byte_size(value) == width,
    do: value =~ ~r/\A[0-9a-f]+\z/

  defp valid_id?(_value, _width), do: false

  defp encode_param(%DateTime{} = value), do: DateTime.to_unix(value, :nanosecond)
  defp encode_param(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_param(value), do: value

  defp excerpt(body) when is_binary(body), do: binary_part(body, 0, min(byte_size(body), 1_024))
end
