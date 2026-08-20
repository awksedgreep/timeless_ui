defmodule TimelessUI.Accounts.LoginThrottleTest do
  use ExUnit.Case, async: false

  alias TimelessUI.Accounts.LoginThrottle

  setup do
    LoginThrottle.reset_all()

    on_exit(fn ->
      LoginThrottle.reset_all()
      System.delete_env("TIMELESS_LOGIN_MAX_ATTEMPTS")
      System.delete_env("TIMELESS_LOGIN_WINDOW_SECONDS")
      System.delete_env("TIMELESS_LOGIN_LOCKOUT_SECONDS")
    end)

    :ok
  end

  test "a fresh source is not locked" do
    refute LoginThrottle.locked?("198.51.100.7")
  end

  test "failures below the threshold do not lock" do
    System.put_env("TIMELESS_LOGIN_MAX_ATTEMPTS", "3")

    assert :ok = LoginThrottle.record_failure("198.51.100.7")
    assert :ok = LoginThrottle.record_failure("198.51.100.7")
    refute LoginThrottle.locked?("198.51.100.7")
  end

  test "the threshold trips the lockout" do
    System.put_env("TIMELESS_LOGIN_MAX_ATTEMPTS", "3")

    LoginThrottle.record_failure("198.51.100.7")
    LoginThrottle.record_failure("198.51.100.7")
    assert {:locked, seconds} = LoginThrottle.record_failure("198.51.100.7")
    assert seconds > 0
    assert LoginThrottle.locked?("198.51.100.7")
  end

  test "lockout applies only to the offending source" do
    # The operator must stay able to log in while someone else is being blocked;
    # that is the whole reason counters are keyed on source rather than account.
    System.put_env("TIMELESS_LOGIN_MAX_ATTEMPTS", "2")

    LoginThrottle.record_failure("203.0.113.9")
    LoginThrottle.record_failure("203.0.113.9")

    assert LoginThrottle.locked?("203.0.113.9")
    refute LoginThrottle.locked?("198.51.100.7")
  end

  test "a successful login clears the counter" do
    System.put_env("TIMELESS_LOGIN_MAX_ATTEMPTS", "3")

    LoginThrottle.record_failure("198.51.100.7")
    LoginThrottle.record_failure("198.51.100.7")
    LoginThrottle.clear("198.51.100.7")

    # Back to a clean slate: the next two failures must not trip the threshold.
    assert :ok = LoginThrottle.record_failure("198.51.100.7")
    assert :ok = LoginThrottle.record_failure("198.51.100.7")
    refute LoginThrottle.locked?("198.51.100.7")
  end

  test "an expired lockout stops blocking" do
    System.put_env("TIMELESS_LOGIN_MAX_ATTEMPTS", "1")
    System.put_env("TIMELESS_LOGIN_LOCKOUT_SECONDS", "1")

    assert {:locked, 1} = LoginThrottle.record_failure("198.51.100.7")
    assert LoginThrottle.locked?("198.51.100.7")

    Process.sleep(1100)
    refute LoginThrottle.locked?("198.51.100.7")
  end

  test "failures outside the window start a fresh count" do
    System.put_env("TIMELESS_LOGIN_MAX_ATTEMPTS", "2")
    System.put_env("TIMELESS_LOGIN_WINDOW_SECONDS", "1")

    assert :ok = LoginThrottle.record_failure("198.51.100.7")
    Process.sleep(1100)

    # Stale failures must not accumulate, or a slow trickle would eventually lock
    # out a legitimate user who mistypes occasionally over weeks.
    assert :ok = LoginThrottle.record_failure("198.51.100.7")
    refute LoginThrottle.locked?("198.51.100.7")
  end

  test "invalid configuration falls back to the default rather than crashing" do
    System.put_env("TIMELESS_LOGIN_MAX_ATTEMPTS", "not-a-number")

    assert LoginThrottle.max_attempts() == 10
  end
end
