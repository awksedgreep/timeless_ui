defmodule TimelessUI.Poller.SnmpKitStarter do
  @moduledoc "Ensures SnmpKit components are started before SNMP operations."

  def ensure_started do
    SnmpKit.SnmpMgr.ensure_started()
  end
end
