defmodule TimelessUI.Poller.Collector do
  @moduledoc """
  Behaviour for poller collectors.

  Each collector type (ICMP, SNMP, Prometheus, etc.) implements this behaviour
  to define how metrics are collected from hosts.
  """

  @type metric_data :: %{
          name: String.t(),
          host: String.t(),
          type: String.t(),
          labels: map(),
          val: number(),
          ts: integer()
        }

  @type config :: map()
  @type host :: TimelessUI.Poller.Host.t()
  @type request :: TimelessUI.Poller.Request.t()

  @doc "Initialize the collector (called once at startup)."
  @callback init(config()) :: :ok | {:error, term()}

  @doc "Validate request config for this collector type."
  @callback validate_config(config()) :: :ok | {:error, term()}

  @doc "Execute a collection against a host with the given request config."
  @callback execute(host(), request(), config(), keyword()) ::
              {:ok, [metric_data()]} | {:error, term()}
end
