defmodule TimelessUI.MetricsDataPlane.PromQL do
  @moduledoc """
  The PromQL a canvas element's query is, and the canvas's shape of what
  comes back.

  A canvas ranks and combines series through the plane's PromQL routes; the
  native range route asks only what a label equals, and cannot group or
  rank. This module is the translation, with no HTTP in it, so that any
  data source over the plane can use it.

  Values in a selector are quoted as PromQL quotes them, and a value that is
  one of several is a regular expression of the values escaped, so a process
  named `MyApp.Repo<0.512.0>` or a unit named `user@1000.service` is asked
  for as it is named.
  """

  alias TimelessCanvas.Canvas.Element

  @type matcher :: {String.t(), :eq | :neq, [String.t()]}
  @type row :: %{labels: %{String.t() => String.t()}, value: float()}
  @type point :: {integer(), float()}

  @aggregates ~w(sum avg max min)a

  @doc """
  A selector for `metric` by an element's matchers
  (`TimelessCanvas.Canvas.Element.query_matchers/1`).
  """
  @spec selector(String.t(), [matcher()]) :: String.t()
  def selector(metric, matchers) when is_binary(metric) and is_list(matchers) do
    inner =
      Enum.map_join(matchers, ",", fn
        {key, :eq, [value]} -> ~s(#{key}="#{quoted(value)}")
        {key, :neq, [value]} -> ~s(#{key}!="#{quoted(value)}")
        {key, :eq, values} -> ~s(#{key}=~"#{any_of(values)}")
        {key, :neq, values} -> ~s(#{key}!~"#{any_of(values)}")
      end)

    "#{metric}{#{inner}}"
  end

  @doc """
  The query behind `c:TimelessCanvas.DataSource.top_series/5`: the top (or
  bottom) `:limit` of the metric's series, grouped by `:group_by` and
  combined with `:aggregate`, or the series themselves with nothing to group
  by.
  """
  @spec top_query(String.t(), [matcher()], keyword()) :: String.t()
  def top_query(metric, matchers, opts) do
    selector = selector(metric, matchers)
    rank = if Keyword.get(opts, :order) == :asc, do: "bottomk", else: "topk"
    limit = Keyword.get(opts, :limit, 10)

    inner =
      case Keyword.get(opts, :group_by, []) do
        [] -> selector
        keys -> "#{aggregate(opts)} by (#{Enum.join(keys, ",")}) (#{selector})"
      end

    "#{rank}(#{limit}, #{inner})"
  end

  @doc """
  The query behind `c:TimelessCanvas.DataSource.metric_range/6`: the series
  combined by `:aggregate`, or the selector alone where there is none.
  """
  @spec range_query(String.t(), [matcher()], keyword()) :: String.t()
  def range_query(metric, matchers, opts) do
    selector = selector(metric, matchers)

    case Keyword.get(opts, :aggregate) do
      nil -> selector
      _aggregate -> "#{aggregate(opts)}(#{selector})"
    end
  end

  @doc """
  The rows of an instant query's answer, in the canvas's shape and in
  `order`. What is not a row is left out; a body that is not an answer is
  an error.
  """
  @spec rows(term(), :desc | :asc) :: {:ok, [row()]} | {:error, term()}
  def rows(%{"status" => "success", "data" => %{"result" => result}}, order)
      when is_list(result) do
    rows =
      result
      |> Enum.flat_map(fn
        %{"metric" => labels, "value" => [_time, value]} when is_map(labels) ->
          case number(value) do
            {:ok, number} -> [%{labels: Map.delete(labels, "__name__"), value: number}]
            :error -> []
          end

        _other ->
          []
      end)
      |> Enum.sort_by(& &1.value, if(order == :asc, do: :asc, else: :desc))

    {:ok, rows}
  end

  def rows(body, _order), do: {:error, {:invalid_promql_response, excerpt(body)}}

  @doc """
  The series of a range query's answer, each as the canvas's points: unix
  milliseconds and a float, oldest first, with the series' labels.
  """
  @spec series(term()) :: {:ok, [%{labels: map(), points: [point()]}]} | {:error, term()}
  def series(%{"status" => "success", "data" => %{"result" => result}}) when is_list(result) do
    {:ok,
     Enum.flat_map(result, fn
       %{"metric" => labels, "values" => values} when is_map(labels) and is_list(values) ->
         [%{labels: Map.delete(labels, "__name__"), points: points(values)}]

       _other ->
         []
     end)}
  end

  def series(body), do: {:error, {:invalid_promql_response, excerpt(body)}}

  defp points(values) do
    Enum.flat_map(values, fn
      [time, value] when is_number(time) ->
        case number(value) do
          {:ok, number} -> [{round(time * 1000), number}]
          :error -> []
        end

      _other ->
        []
    end)
  end

  # Prometheus writes a sample's value as text. NaN and the infinities are
  # values it can write and the canvas cannot draw.
  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, number}
      _other -> :error
    end
  end

  defp number(value) when is_integer(value), do: {:ok, value * 1.0}
  defp number(value) when is_float(value), do: {:ok, value}
  defp number(_value), do: :error

  defp aggregate(opts) do
    case Keyword.get(opts, :aggregate) do
      aggregate when aggregate in @aggregates -> Atom.to_string(aggregate)
      _other -> "sum"
    end
  end

  defp quoted(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end

  defp any_of(values),
    do: Enum.map_join(values, "|", &(&1 |> to_string() |> Regex.escape() |> quoted()))

  defp excerpt(body) do
    text = inspect(body)
    binary_part(text, 0, min(byte_size(text), 200))
  end

  @doc """
  The matchers of an element, for callers that have one.
  """
  @spec matchers(Element.t() | map()) :: [matcher()]
  def matchers(element), do: Element.query_matchers(element)
end
