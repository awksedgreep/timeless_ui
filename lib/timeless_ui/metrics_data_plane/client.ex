defmodule TimelessUI.MetricsDataPlane.Client do
  @moduledoc """
  Thin HTTP client for complete operations against the Rust metrics data plane.

  This adapter deliberately owns no telemetry database connection. Responses are
  decoded only after Req has received the complete HTTP body, and an invalid line
  invalidates the complete response rather than exposing a partial result.
  """

  alias TimelessUI.MetricsDataPlane.Process, as: DataPlaneProcess

  @default_timeout 30_000

  def health(opts \\ []), do: json_request(:get, "/health", opts)
  def stats(opts \\ []), do: json_request(:get, "/select/metrics/stats", opts)
  def flush(opts \\ []), do: json_request(:post, "/api/v1/flush", opts)

  def import_victoria(body, opts \\ []) when is_binary(body) do
    expect_empty_success(:post, "/api/v1/import", body, opts)
  end

  def import_prometheus(body, opts \\ []) when is_binary(body) do
    expect_empty_success(:post, "/api/v1/import/prometheus", body, opts)
  end

  def latest(metric, labels \\ %{}, opts \\ [])
      when is_binary(metric) and is_map(labels) do
    params = labels |> Map.put("metric", metric)
    json_request(:get, "/api/v1/query", Keyword.put(opts, :params, params))
  end

  def range(metric, labels, from, to, step, aggregate, opts \\ [])
      when is_binary(metric) and is_map(labels) and is_integer(from) and is_integer(to) and
             is_integer(step) and step > 0 and
             aggregate in [:avg, :min, :max, :sum, :count, :last, :first, :rate] do
    params =
      labels
      |> Map.merge(%{
        "metric" => metric,
        "start" => from,
        "end" => to,
        "step" => step,
        "aggregate" => Atom.to_string(aggregate)
      })

    json_request(:get, "/api/v1/query_range", Keyword.put(opts, :params, params))
  end

  def labels(opts \\ []), do: data_array_request("/api/v1/labels", %{}, opts)

  def label_values(name, params \\ %{}, opts \\ []) when is_binary(name) and is_map(params) do
    data_array_request("/api/v1/label/#{URI.encode(name)}/values", params, opts)
  end

  def series(metric, opts \\ []) when is_binary(metric) do
    data_array_request("/api/v1/series", %{"metric" => metric}, opts)
  end

  def prometheus_instant(query, time \\ nil, opts \\ []) when is_binary(query) do
    params = maybe_put(%{"query" => query}, "time", time)
    json_request(:get, "/prometheus/api/v1/query", Keyword.put(opts, :params, params))
  end

  def prometheus_range(query, from, to, step, opts \\ [])
      when is_binary(query) and is_integer(from) and is_integer(to) do
    params = %{"query" => query, "start" => from, "end" => to, "step" => step}
    json_request(:get, "/prometheus/api/v1/query_range", Keyword.put(opts, :params, params))
  end

  defp expect_empty_success(method, path, body, opts) do
    case raw_request(method, path, Keyword.put(opts, :body, body)) do
      {:ok, 204, ""} ->
        :ok

      {:ok, status, response_body} ->
        {:error, {:unexpected_response, status, excerpt(response_body)}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Return complete raw series in Canvas-friendly millisecond timestamps."
  def export(metric, labels, from, to, opts \\ [])
      when is_binary(metric) and is_map(labels) and is_integer(from) and is_integer(to) do
    params =
      labels
      |> Map.put("metric", metric)
      |> Map.put("from", from)
      |> Map.put("to", to)

    with {:ok, 200, body} <-
           raw_request(:get, "/api/v1/export", Keyword.put(opts, :params, params)),
         {:ok, series} <- decode_export(body) do
      {:ok, series}
    else
      {:ok, status, body} -> {:error, {:unexpected_response, status, excerpt(body)}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def request_json(method, path, opts \\ []), do: json_request(method, path, opts)

  defp data_array_request(path, params, opts) do
    with {:ok, %{"status" => "success", "data" => data}} when is_list(data) <-
           json_request(:get, path, Keyword.put(opts, :params, params)) do
      {:ok, data}
    else
      {:ok, _body} -> {:error, :invalid_discovery_response}
      {:error, _reason} = error -> error
    end
  end

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
        case loopback_endpoint(endpoint) do
          {:ok, endpoint} -> {:ok, endpoint, nil}
          {:error, _reason} = error -> error
        end

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

  defp authorization_header?({name, _value}) do
    String.downcase(to_string(name)) == "authorization"
  end

  defp loopback_endpoint(endpoint) do
    uri = URI.parse(endpoint)

    with "http" <- uri.scheme,
         host when is_binary(host) <- uri.host,
         {:ok, address} <- :inet.parse_address(String.to_charlist(host)),
         true <- loopback_address?(address),
         true <- uri.userinfo == nil and uri.query == nil and uri.fragment == nil,
         true <- uri.path in [nil, "", "/"] do
      {:ok, String.trim_trailing(endpoint, "/")}
    else
      _ -> {:error, {:metrics_data_plane_must_use_loopback, endpoint}}
    end
  end

  defp loopback_address?({127, _, _, _}), do: true
  defp loopback_address?(_address), do: false

  defp decode_export(""), do: {:ok, []}

  defp decode_export(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, rows} ->
      case decode_export_line(line) do
        {:ok, row} -> {:cont, {:ok, [row | rows]}}
        {:error, reason} -> {:halt, {:error, {:invalid_response, reason}}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_export_line(line) do
    with {:ok, %{"metric" => metric, "timestamps" => timestamps, "values" => values}} <-
           Jason.decode(line),
         true <- is_map(metric) and is_list(timestamps) and is_list(values),
         true <- length(timestamps) == length(values),
         {name, labels} when is_binary(name) <- Map.pop(metric, "__name__"),
         true <- Enum.all?(timestamps, &is_integer/1),
         true <- Enum.all?(values, &(is_integer(&1) or is_float(&1))) do
      {:ok,
       %{
         metric: name,
         labels: labels,
         points: Enum.zip(timestamps, Enum.map(values, &(&1 * 1.0)))
       }}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, error}
      _ -> {:error, :invalid_export_shape}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp excerpt(body) when is_binary(body), do: binary_part(body, 0, min(byte_size(body), 1_024))
  defp excerpt(body), do: inspect(body)
end
