defmodule TimelessUIWeb.ClientIPTest do
  use ExUnit.Case, async: false

  alias TimelessUIWeb.ClientIP

  defp conn_from(peer, forwarded \\ nil) do
    conn = Plug.Test.conn(:post, "/users/log-in")
    conn = %{conn | remote_ip: peer}

    case forwarded do
      nil -> conn
      value -> Plug.Conn.put_req_header(conn, "x-forwarded-for", value)
    end
  end

  describe "when the peer is not a trusted proxy" do
    test "ignores X-Forwarded-For entirely" do
      # This is the security-critical case. Believing a header from an untrusted
      # peer would let an attacker rotate it to dodge rate limiting, or forge a
      # victim's address to get them locked out instead.
      conn = conn_from({203, 0, 113, 9}, "1.2.3.4")

      assert ClientIP.resolve(conn) == "203.0.113.9"
    end

    test "uses the peer when no header is present" do
      assert ClientIP.resolve(conn_from({203, 0, 113, 9})) == "203.0.113.9"
    end
  end

  describe "when the peer is a trusted proxy" do
    test "uses the forwarded address" do
      conn = conn_from({127, 0, 0, 1}, "198.51.100.7")

      assert ClientIP.resolve(conn) == "198.51.100.7"
    end

    test "takes the rightmost address that is not itself a trusted proxy" do
      conn = conn_from({127, 0, 0, 1}, "198.51.100.7, 127.0.0.1")

      assert ClientIP.resolve(conn) == "198.51.100.7"
    end

    test "prefers the closest hop when a chain is forwarded" do
      # Anything left of the last untrusted hop is attacker-supplied and must not
      # win: only the rightmost untrusted entry was actually observed by a proxy
      # we trust.
      conn = conn_from({127, 0, 0, 1}, "1.1.1.1, 198.51.100.7")

      assert ClientIP.resolve(conn) == "198.51.100.7"
    end

    test "falls back to the peer when the header is unparseable" do
      conn = conn_from({127, 0, 0, 1}, "not-an-ip")

      assert ClientIP.resolve(conn) == "127.0.0.1"
    end

    test "falls back to the peer when every hop is trusted" do
      conn = conn_from({127, 0, 0, 1}, "127.0.0.1")

      assert ClientIP.resolve(conn) == "127.0.0.1"
    end

    test "strips an appended port" do
      conn = conn_from({127, 0, 0, 1}, "198.51.100.7:44321")

      assert ClientIP.resolve(conn) == "198.51.100.7"
    end
  end

  describe "trusted?/1" do
    test "loopback is trusted by default" do
      assert ClientIP.trusted?({127, 0, 0, 1})
      assert ClientIP.trusted?({127, 5, 5, 5})
      assert ClientIP.trusted?({0, 0, 0, 0, 0, 0, 0, 1})
    end

    test "public addresses are not" do
      refute ClientIP.trusted?({198, 51, 100, 7})
      refute ClientIP.trusted?({8, 8, 8, 8})
    end

    test "an IPv4 address is not inside an IPv6 network" do
      refute ClientIP.trusted?({10, 0, 0, 1})
    end

    test "honours TIMELESS_TRUSTED_PROXIES" do
      System.put_env("TIMELESS_TRUSTED_PROXIES", "10.0.0.0/8")

      try do
        assert ClientIP.trusted?({10, 1, 2, 3})
        refute ClientIP.trusted?({127, 0, 0, 1})
      after
        System.delete_env("TIMELESS_TRUSTED_PROXIES")
      end
    end

    test "ignores malformed entries rather than trusting everything" do
      System.put_env("TIMELESS_TRUSTED_PROXIES", "garbage,10.0.0.0/8")

      try do
        assert ClientIP.trusted?({10, 1, 2, 3})
        refute ClientIP.trusted?({198, 51, 100, 7})
      after
        System.delete_env("TIMELESS_TRUSTED_PROXIES")
      end
    end
  end
end
