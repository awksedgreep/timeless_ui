defmodule TimelessUI.Poller.SnmpKitStarter do
  @moduledoc "Ensures SnmpKit components are started before SNMP operations."

  require Logger

  def ensure_started do
    components = [
      {SnmpKit.SnmpMgr.Config, fn -> SnmpKit.SnmpMgr.Config.start_link([]) end},
      {SnmpKit.SnmpMgr.RequestIdGenerator,
       fn ->
         SnmpKit.SnmpMgr.RequestIdGenerator.start_link(
           name: SnmpKit.SnmpMgr.RequestIdGenerator
         )
       end},
      {SnmpKit.SnmpMgr.SocketManager,
       fn ->
         SnmpKit.SnmpMgr.SocketManager.start_link(name: SnmpKit.SnmpMgr.SocketManager)
       end},
      {SnmpKit.SnmpMgr.EngineV2,
       fn -> SnmpKit.SnmpMgr.EngineV2.start_link(name: SnmpKit.SnmpMgr.EngineV2) end}
    ]

    Enum.each(components, fn {name, start_fn} ->
      unless Process.whereis(name), do: start_fn.()
    end)

    :ok
  end
end
