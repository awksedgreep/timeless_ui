defmodule TimelessUI.Accounts.LoginThrottle do
  @moduledoc """
  Counts failed logins per source and locks a source out once it crosses a
  threshold within a sliding window.

  ## Why the source, not the account

  Counters are keyed on the client IP rather than the username on purpose. A
  purely account-keyed lockout means anyone on the internet can lock the admin
  account at will, and would do so at the worst possible moment — this UI exists
  to be reached *during* an incident. Locking the offending source contains an
  attacker without handing them the ability to lock the operator out.

  ## Storage

  An ETS table owned by this process, swept periodically. Counters are
  deliberately not persisted: they are cheap to rebuild, a restart is not
  attacker-triggerable here, and a write per failed attempt on the request path
  is not worth it.

  ## Configuration

  All three are read at runtime from the environment:

    * `TIMELESS_LOGIN_MAX_ATTEMPTS` — failures before lockout (default `10`)
    * `TIMELESS_LOGIN_WINDOW_SECONDS` — sliding window (default `900`)
    * `TIMELESS_LOGIN_LOCKOUT_SECONDS` — lockout duration (default `900`)

  The defaults are deliberately generous: ordinary typos should never trip this,
  and bcrypt already makes online guessing slow. The point is to bound an
  automated attempt rate, not to police human fumbling.
  """

  use GenServer

  require Logger

  @table :timeless_ui_login_throttle
  @sweep_interval_ms 60_000

  @default_max_attempts 10
  @default_window_seconds 900
  @default_lockout_seconds 900

  # Client

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Whether this source is currently locked out.
  """
  @spec locked?(String.t()) :: boolean()
  def locked?(source) do
    now = System.system_time(:second)

    case :ets.lookup(@table, source) do
      [{^source, _count, _first_at, locked_until}] when is_integer(locked_until) ->
        locked_until > now

      _ ->
        false
    end
  end

  @doc """
  Record a failed attempt. Returns `:ok`, or `{:locked, seconds_remaining}` when
  this failure is the one that trips the lockout.
  """
  @spec record_failure(String.t()) :: :ok | {:locked, pos_integer()}
  def record_failure(source) do
    now = System.system_time(:second)
    window = window_seconds()
    max_attempts = max_attempts()

    count =
      case :ets.lookup(@table, source) do
        # Window expired — start a fresh count rather than carrying stale failures forward.
        [{^source, _count, first_at, _locked_until}] when now - first_at >= window ->
          :ets.insert(@table, {source, 1, now, nil})
          1

        [{^source, count, first_at, locked_until}] ->
          :ets.insert(@table, {source, count + 1, first_at, locked_until})
          count + 1

        [] ->
          :ets.insert(@table, {source, 1, now, nil})
          1
      end

    if count >= max_attempts do
      lockout = lockout_seconds()
      [{^source, count, first_at, _}] = :ets.lookup(@table, source)
      :ets.insert(@table, {source, count, first_at, now + lockout})
      {:locked, lockout}
    else
      :ok
    end
  end

  @doc """
  Clear the counter for a source after a successful login.
  """
  @spec clear(String.t()) :: :ok
  def clear(source) do
    :ets.delete(@table, source)
    :ok
  end

  @doc false
  def reset_all do
    :ets.delete_all_objects(@table)
    :ok
  end

  def max_attempts, do: env_int("TIMELESS_LOGIN_MAX_ATTEMPTS", @default_max_attempts)
  def window_seconds, do: env_int("TIMELESS_LOGIN_WINDOW_SECONDS", @default_window_seconds)
  def lockout_seconds, do: env_int("TIMELESS_LOGIN_LOCKOUT_SECONDS", @default_lockout_seconds)

  defp env_int(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {int, ""} when int > 0 ->
            int

          _ ->
            Logger.warning("Invalid #{name}=#{inspect(value)}, using default #{default}")
            default
        end
    end
  end

  # Server

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  # Drop entries whose window has elapsed and whose lockout, if any, has expired.
  # Without this the table grows once per attacking source, forever.
  defp sweep do
    now = System.system_time(:second)
    window = window_seconds()

    :ets.foldl(
      fn {source, _count, first_at, locked_until}, acc ->
        expired_window? = now - first_at >= window
        lock_done? = is_nil(locked_until) or locked_until <= now

        if expired_window? and lock_done?, do: [source | acc], else: acc
      end,
      [],
      @table
    )
    |> Enum.each(&:ets.delete(@table, &1))
  end
end
