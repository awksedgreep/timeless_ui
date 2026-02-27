alias TimelessUI.Poller.SnmpTables

# ── Table definitions ──────────────────────────────────────────────
#
# Each entry: {column_id, name, data_type, description}
# With is_index: {column_id, name, data_type, description, true}
# Foreign keys: {column_id, name, data_type, is_index, foreign_table, foreign_column, description}

tables = [
  %{
    name: "ifTable",
    base_oid: "1.3.6.1.2.1.2.2.1",
    index_pattern: ".{column}.{ifIndex}",
    description: "IF-MIB standard interface table",
    columns: [
      {2, "ifDescr", "string", "Interface description"},
      {3, "ifType", "integer", "Interface type"},
      {5, "ifSpeed", "gauge", "Interface speed in bits/sec"},
      {7, "ifAdminStatus", "integer", "Administrative status"},
      {8, "ifOperStatus", "integer", "Operational status"},
      {10, "ifInOctets", "counter32", "Inbound octets"},
      {16, "ifOutOctets", "counter32", "Outbound octets"}
    ],
    foreign_keys: []
  },
  %{
    name: "ifXTable",
    base_oid: "1.3.6.1.2.1.31.1.1.1",
    index_pattern: ".{column}.{ifIndex}",
    description: "IF-MIB extended interface table with 64-bit counters",
    columns: [
      {1, "ifName", "string", "Interface name"},
      {6, "ifHCInOctets", "counter64", "High capacity inbound octets"},
      {7, "ifHCInUcastPkts", "counter64", "High capacity inbound unicast packets"},
      {8, "ifHCInMulticastPkts", "counter64", "High capacity inbound multicast packets"},
      {9, "ifHCInBroadcastPkts", "counter64", "High capacity inbound broadcast packets"},
      {10, "ifHCOutOctets", "counter64", "High capacity outbound octets"},
      {11, "ifHCOutUcastPkts", "counter64", "High capacity outbound unicast packets"},
      {12, "ifHCOutMulticastPkts", "counter64", "High capacity outbound multicast packets"},
      {13, "ifHCOutBroadcastPkts", "counter64", "High capacity outbound broadcast packets"},
      {15, "ifHighSpeed", "gauge", "Interface speed in Mbps"},
      {18, "ifAlias", "string", "Interface alias"}
    ],
    foreign_keys: []
  },
  %{
    name: "docsIfDownstreamChannelTable",
    base_oid: "1.3.6.1.2.1.10.127.1.1.1.1",
    index_pattern: ".{column}.{ifIndex}",
    description: "DOCSIS downstream channel parameters",
    columns: [
      {1, "docsIfDownChannelId", "integer", "Channel ID"},
      {2, "docsIfDownChannelFrequency", "integer", "Channel frequency in Hz"},
      {3, "docsIfDownChannelWidth", "integer", "Channel width in Hz"},
      {4, "docsIfDownChannelModulation", "integer", "Modulation type"},
      {5, "docsIfDownChannelInterleave", "integer", "Interleave depth"},
      {6, "docsIfDownChannelPower", "integer", "Power level in dBmV"}
    ],
    foreign_keys: [
      {0, "ifIndex", "integer", true, "ifXTable", "ifName", "Interface index"}
    ]
  },
  %{
    name: "docsIfUpstreamChannelTable",
    base_oid: "1.3.6.1.2.1.10.127.1.1.2.1",
    index_pattern: ".{column}.{ifIndex}",
    description: "DOCSIS upstream channel parameters",
    columns: [
      {1, "docsIfUpChannelId", "integer", "Channel ID"},
      {2, "docsIfUpChannelFrequency", "integer", "Channel frequency in Hz"},
      {3, "docsIfUpChannelWidth", "integer", "Channel width in Hz"},
      {4, "docsIfUpChannelModulationProfile", "integer", "Modulation profile index"},
      {5, "docsIfUpChannelSlotSize", "integer", "Mini-slot size in ticks"},
      {7, "docsIfUpChannelRangingBackoffStart", "integer", "Ranging backoff start"},
      {8, "docsIfUpChannelRangingBackoffEnd", "integer", "Ranging backoff end"},
      {9, "docsIfUpChannelTxBackoffStart", "integer", "Transmit backoff start"},
      {10, "docsIfUpChannelTxBackoffEnd", "integer", "Transmit backoff end"}
    ],
    foreign_keys: [
      {0, "ifIndex", "integer", true, "ifXTable", "ifName", "Interface index"}
    ]
  },
  %{
    name: "docsIfCmtsCmStatusTable",
    base_oid: "1.3.6.1.2.1.10.127.1.3.3.1",
    index_pattern: ".{column}.{ifIndex}",
    description: "DOCSIS CMTS cable modem status table",
    columns: [
      {1, "docsIfCmtsCmStatusIndex", "integer", "CM status index", true},
      {2, "docsIfCmtsCmStatusMacAddress", "octet_string", "MAC address of the cable modem"},
      {3, "docsIfCmtsCmStatusIpAddress", "ip_address", "IP address of the cable modem"},
      {6, "docsIfCmtsCmStatusRxPower", "integer", "Received power in dBmV"},
      {7, "docsIfCmtsCmStatusTimingOffset", "gauge", "Timing offset"},
      {9, "docsIfCmtsCmStatusValue", "integer", "CM status value"},
      {10, "docsIfCmtsCmStatusUnerroreds", "counter32", "Unerrored codewords"},
      {11, "docsIfCmtsCmStatusCorrecteds", "counter32", "Corrected codewords"},
      {12, "docsIfCmtsCmStatusUncorrectables", "counter32", "Uncorrectable codewords"},
      {13, "docsIfCmtsCmStatusSignalNoise", "integer", "Signal to noise ratio"},
      {14, "docsIfCmtsCmStatusMicroreflections", "integer", "Microreflections in dBc"},
      {15, "docsIfCmtsCmStatusEqualizationData", "octet_string", "Equalization data"},
      {16, "docsIfCmtsCmStatusTxPower", "integer", "Transmit power in dBmV"},
      {17, "docsIfCmtsCmStatusHighResolutionTimingOffset", "gauge",
       "High resolution timing offset"},
      {19, "docsIfCmtsCmStatusDocsisModemCapabilities", "octet_string",
       "DOCSIS modem capabilities"},
      {20, "docsIfCmtsCmStatusModulationType", "integer", "Modulation type"}
    ],
    foreign_keys: [
      {4, "docsIfCmtsCmStatusDownChannelIfIndex", "integer", false,
       "docsIfDownstreamChannelTable", "ifIndex", "Downstream channel interface index"},
      {5, "docsIfCmtsCmStatusUpChannelIfIndex", "integer", false, "docsIfUpstreamChannelTable",
       "ifIndex", "Upstream channel interface index"}
    ]
  }
]

for table_def <- tables do
  # Skip if already seeded
  if SnmpTables.get_table_by_name(table_def.name) do
    IO.puts("  Skipping #{table_def.name} (already exists)")
  else
    IO.puts("  Creating table: #{table_def.name}")

    {:ok, table} =
      SnmpTables.create_table(%{
        name: table_def.name,
        base_oid: table_def.base_oid,
        index_pattern: table_def.index_pattern,
        description: table_def.description
      })

    # Seed regular columns
    for col <- table_def.columns do
      {column_id, name, data_type, description} =
        case col do
          {id, n, dt, desc, _is_idx} -> {id, n, dt, desc}
          {id, n, dt, desc} -> {id, n, dt, desc}
        end

      is_index = match?({_, _, _, _, true}, col)

      {:ok, _} =
        SnmpTables.create_column(table, %{
          name: name,
          column_id: column_id,
          data_type: data_type,
          is_index: is_index,
          description: description
        })
    end

    # Seed foreign key columns
    for {column_id, name, data_type, is_index, foreign_table, foreign_column, description} <-
          table_def.foreign_keys do
      {:ok, _} =
        SnmpTables.create_column(table, %{
          name: name,
          column_id: column_id,
          data_type: data_type,
          is_index: is_index,
          foreign_table: foreign_table,
          foreign_column: foreign_column,
          description: description
        })
    end
  end
end

IO.puts("SNMP table seeding complete.")
