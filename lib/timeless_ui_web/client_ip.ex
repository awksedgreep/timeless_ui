defmodule TimelessUIWeb.ClientIP do
  @moduledoc """
  Resolves the real client IP, honouring `X-Forwarded-For` only from trusted
  proxies.

  ## Why this is needed

  The production deployment terminates TLS at a reverse proxy and forwards to
  `127.0.0.1:4000`. Every request therefore arrives from the proxy, and
  `conn.remote_ip` is the proxy for all of them. Anything keyed on the client
  address — rate limiting, lockout, abuse logging — would see a single source
  and either do nothing useful or punish every user at once.

  ## Why the trust check matters

  `X-Forwarded-For` is a client-supplied header. Believing it unconditionally is
  worse than ignoring it: an attacker could vary it to evade a rate limit, or
  forge someone else's address to get *them* locked out. So the header is only
  consulted when the immediate peer is itself a trusted proxy, and the value
  taken is the rightmost entry that is not a trusted proxy — the last address
  the trusted chain actually observed.

  ## Configuration

  `TIMELESS_TRUSTED_PROXIES` is a comma-separated list of CIDRs, defaulting to
  loopback only (`127.0.0.0/8,::1/128`), which matches a reverse proxy running
  on the same host. Widen it only for proxies you genuinely control.
  """

  import Bitwise
  require Logger

  @default_trusted "127.0.0.0/8,::1/128"

  @doc """
  Return the client IP for this connection as a string.
  """
  @spec resolve(Plug.Conn.t()) :: String.t()
  def resolve(%Plug.Conn{remote_ip: peer} = conn) do
    if trusted?(peer) do
      conn
      |> forwarded_for()
      |> Enum.reverse()
      |> Enum.find(fn ip -> not trusted?(ip) end)
      |> case do
        nil -> ip_to_string(peer)
        ip -> ip_to_string(ip)
      end
    else
      # Peer is not a trusted proxy, so any XFF it sent is unverifiable. Ignore it.
      ip_to_string(peer)
    end
  end

  defp ip_to_string(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> List.to_string()

  defp forwarded_for(conn) do
    conn
    |> Plug.Conn.get_req_header("x-forwarded-for")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(fn value ->
      case :inet.parse_address(String.to_charlist(strip_port(value))) do
        {:ok, ip} -> [ip]
        {:error, _} -> []
      end
    end)
  end

  # Some proxies append a port ("1.2.3.4:5678"). Bracketed IPv6 may too.
  defp strip_port("[" <> rest) do
    rest |> String.split("]") |> List.first()
  end

  defp strip_port(value) do
    case String.split(value, ":") do
      [ipv4, _port] -> ipv4
      _ -> value
    end
  end

  @doc """
  Whether an address falls inside the configured trusted-proxy set.
  """
  @spec trusted?(:inet.ip_address()) :: boolean()
  def trusted?(ip) when is_tuple(ip) do
    Enum.any?(trusted_cidrs(), fn {net, mask_bits} -> in_network?(ip, net, mask_bits) end)
  end

  defp trusted_cidrs do
    (System.get_env("TIMELESS_TRUSTED_PROXIES") || @default_trusted)
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(&parse_cidr/1)
  end

  defp parse_cidr(cidr) do
    {addr, bits} =
      case String.split(cidr, "/") do
        [addr, bits] -> {addr, Integer.parse(bits)}
        [addr] -> {addr, :no_mask}
      end

    case :inet.parse_address(String.to_charlist(addr)) do
      {:ok, ip} ->
        case bits do
          {int, ""} -> [{ip, int}]
          :no_mask -> [{ip, full_mask(ip)}]
          _ -> invalid(cidr)
        end

      {:error, _} ->
        invalid(cidr)
    end
  end

  defp invalid(cidr) do
    Logger.warning("Ignoring invalid entry in TIMELESS_TRUSTED_PROXIES: #{inspect(cidr)}")
    []
  end

  defp full_mask(ip) when tuple_size(ip) == 4, do: 32
  defp full_mask(ip) when tuple_size(ip) == 8, do: 128

  # Compare only within the same address family; a v4 address is never inside a
  # v6 network and vice versa.
  defp in_network?(ip, net, mask_bits) when tuple_size(ip) == tuple_size(net) do
    size = if tuple_size(ip) == 4, do: 8, else: 16
    total = tuple_size(ip) * size

    if mask_bits < 0 or mask_bits > total do
      false
    else
      shift = total - mask_bits
      to_int(ip, size) >>> shift == to_int(net, size) >>> shift
    end
  end

  defp in_network?(_ip, _net, _mask_bits), do: false

  defp to_int(ip, size) do
    ip
    |> Tuple.to_list()
    |> Enum.reduce(0, fn part, acc -> (acc <<< size) + part end)
  end

end
