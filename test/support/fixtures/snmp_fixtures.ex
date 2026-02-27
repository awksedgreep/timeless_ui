defmodule TimelessUI.SnmpFixtures do
  @moduledoc """
  Test helpers for creating SNMP table and column entities.
  """

  alias TimelessUI.Poller.SnmpTables

  def snmp_table_fixture(attrs \\ %{}) do
    {:ok, table} =
      SnmpTables.create_table(
        Map.merge(
          %{
            name: "ifXTable",
            base_oid: "1.3.6.1.2.1.31.1.1.1",
            index_pattern: ".{column}.{ifIndex}",
            description: "IF-MIB extended interface table"
          },
          attrs
        )
      )

    table
  end

  def snmp_column_fixture(table, attrs \\ %{}) do
    {:ok, column} =
      SnmpTables.create_column(
        table,
        Map.merge(
          %{
            name: "ifHCInOctets",
            column_id: 6,
            data_type: "counter64",
            description: "High capacity inbound octets"
          },
          attrs
        )
      )

    column
  end

  @doc """
  Seeds a complete ifXTable with all 11 columns. Returns the table with columns preloaded.
  """
  def seed_ifx_table do
    table = snmp_table_fixture()

    columns = [
      %{name: "ifName", column_id: 1, data_type: "string", description: "Interface name"},
      %{name: "ifHCInOctets", column_id: 6, data_type: "counter64", description: "HC inbound octets"},
      %{name: "ifHCInUcastPkts", column_id: 7, data_type: "counter64", description: "HC inbound unicast packets"},
      %{name: "ifHCInMulticastPkts", column_id: 8, data_type: "counter64", description: "HC inbound multicast packets"},
      %{name: "ifHCInBroadcastPkts", column_id: 9, data_type: "counter64", description: "HC inbound broadcast packets"},
      %{name: "ifHCOutOctets", column_id: 10, data_type: "counter64", description: "HC outbound octets"},
      %{name: "ifHCOutUcastPkts", column_id: 11, data_type: "counter64", description: "HC outbound unicast packets"},
      %{name: "ifHCOutMulticastPkts", column_id: 12, data_type: "counter64", description: "HC outbound multicast packets"},
      %{name: "ifHCOutBroadcastPkts", column_id: 13, data_type: "counter64", description: "HC outbound broadcast packets"},
      %{name: "ifHighSpeed", column_id: 15, data_type: "gauge", description: "Interface speed in Mbps"},
      %{name: "ifAlias", column_id: 18, data_type: "string", description: "Interface alias"}
    ]

    for col <- columns do
      snmp_column_fixture(table, col)
    end

    # Return with columns preloaded
    TimelessUI.Repo.preload(table, :columns)
  end
end
