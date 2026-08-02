defmodule TimelessUI.ApplicationTest do
  use ExUnit.Case, async: false

  defmodule AccountsProbe do
    def ensure_admin_user do
      send(Application.fetch_env!(:timeless_ui, :accounts_probe_owner), :admin_bootstrap_called)
      :exists
    end
  end

  test "a failed supervision-tree start never performs post-start account work" do
    previous_accounts = Application.get_env(:timeless_ui, :accounts_module)
    previous_owner = Application.get_env(:timeless_ui, :accounts_probe_owner)

    Application.put_env(:timeless_ui, :accounts_module, AccountsProbe)
    Application.put_env(:timeless_ui, :accounts_probe_owner, self())

    on_exit(fn ->
      restore_env(:accounts_module, previous_accounts)
      restore_env(:accounts_probe_owner, previous_owner)
    end)

    assert {:error, {:already_started, _pid}} = TimelessUI.Application.start(:normal, [])
    refute_receive :admin_bootstrap_called
  end

  defp restore_env(key, nil), do: Application.delete_env(:timeless_ui, key)
  defp restore_env(key, value), do: Application.put_env(:timeless_ui, key, value)
end
