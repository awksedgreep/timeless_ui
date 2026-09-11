defmodule TimelessUI.Poller.Snmp.TableLoaderTest do
  use TimelessUI.DataCase, async: false

  alias TimelessUI.Poller.Snmp.TableLoader

  import TimelessUI.SnmpFixtures

  setup do
    table = seed_ifx_table()
    %{table: table}
  end

  describe "get_table/1" do
    test "returns table definition with columns keyed by column_id" do
      table_def = TableLoader.get_table("ifXTable")

      assert table_def.name == "ifXTable"
      assert table_def.base_oid == "1.3.6.1.2.1.31.1.1.1"
      assert table_def.index_pattern == ".{column}.{ifIndex}"
      assert table_def.index_names == ["ifIndex"]
      assert is_map(table_def.columns)
      assert map_size(table_def.columns) == 11

      # Columns keyed by column_id (oid_suffix)
      assert %{name: "ifName", type: "string"} = table_def.columns[1]
      assert %{name: "ifHCInOctets", type: "counter64"} = table_def.columns[6]
    end

    test "returns nil for unknown table" do
      assert TableLoader.get_table("nonExistentTable") == nil
    end

    test "caches definitions and explicit invalidation observes a write", %{table: table} do
      previous = Application.get_env(:timeless_ui, :snmp_table_cache)
      Application.put_env(:timeless_ui, :snmp_table_cache, enabled: true)
      TableLoader.invalidate_all()

      on_exit(fn ->
        Application.put_env(:timeless_ui, :snmp_table_cache, previous)
        TableLoader.invalidate_all()
      end)

      assert TableLoader.get_table("ifXTable").base_oid == table.base_oid

      changed_oid = "1.3.6.1.2.1.31.99"
      table |> Ecto.Changeset.change(base_oid: changed_oid) |> TimelessUI.Repo.update!()

      assert TableLoader.get_table("ifXTable").base_oid == table.base_oid
      assert :ok = TableLoader.invalidate("ifXTable")
      assert TableLoader.get_table("ifXTable").base_oid == changed_oid
    end
  end

  describe "parse_oid/2" do
    test "parses .{column}.{ifIndex} pattern correctly" do
      table_def = TableLoader.get_table("ifXTable")

      assert {:ok, %{column_id: 6, indices: %{"ifIndex" => 3}}} =
               TableLoader.parse_oid("1.3.6.1.2.1.31.1.1.1.6.3", table_def)
    end

    test "parses .{column}.{ifIndex}.{cmIndex} pattern correctly" do
      table =
        snmp_table_fixture(%{
          name: "testCmTable",
          base_oid: "1.3.6.1.2.1.99.1",
          index_pattern: ".{column}.{ifIndex}.{cmIndex}"
        })

      snmp_column_fixture(table, %{name: "testCol", column_id: 1, data_type: "integer"})
      table_def = TableLoader.get_table("testCmTable")

      assert {:ok, %{column_id: 1, indices: %{"ifIndex" => 5, "cmIndex" => 42}}} =
               TableLoader.parse_oid("1.3.6.1.2.1.99.1.1.5.42", table_def)
    end

    test "generic fallback produces string-keyed indices" do
      table =
        snmp_table_fixture(%{
          name: "testGeneric",
          base_oid: "1.3.6.1.2.1.99.2",
          index_pattern: "unknown"
        })

      snmp_column_fixture(table, %{name: "testCol", column_id: 1, data_type: "integer"})
      table_def = TableLoader.get_table("testGeneric")

      assert {:ok, %{column_id: 1, indices: %{"index1" => 7, "index2" => 99}}} =
               TableLoader.parse_oid("1.3.6.1.2.1.99.2.1.7.99", table_def)
    end

    test "returns error for wrong base OID" do
      table_def = TableLoader.get_table("ifXTable")

      assert {:error, :wrong_base_oid} =
               TableLoader.parse_oid("1.3.6.1.2.1.2.2.1.10.1", table_def)
    end
  end

  describe "get_column/2" do
    test "looks up column by column_id" do
      table_def = TableLoader.get_table("ifXTable")

      assert %{name: "ifHCInOctets", type: "counter64"} = TableLoader.get_column(table_def, 6)
    end

    test "returns nil for missing column_id" do
      table_def = TableLoader.get_table("ifXTable")

      assert TableLoader.get_column(table_def, 999) == nil
    end
  end

  describe "get_metric_columns/1" do
    test "returns only counter/gauge/integer/time_ticks columns" do
      table_def = TableLoader.get_table("ifXTable")
      metric_cols = TableLoader.get_metric_columns(table_def)

      metric_names = Enum.map(metric_cols, & &1.name) |> Enum.sort()

      # 8 counter64 + 1 gauge = 9 metric columns
      assert length(metric_cols) == 9
      assert "ifHCInOctets" in metric_names
      assert "ifHCOutOctets" in metric_names
      assert "ifHighSpeed" in metric_names

      # string columns should not be included
      refute "ifName" in metric_names
      refute "ifAlias" in metric_names
    end
  end

  describe "get_label_columns/1" do
    test "returns only string/octet_string/ip_address columns" do
      table_def = TableLoader.get_table("ifXTable")
      label_cols = TableLoader.get_label_columns(table_def)

      label_names = Enum.map(label_cols, & &1.name) |> Enum.sort()

      assert length(label_cols) == 2
      assert "ifName" in label_names
      assert "ifAlias" in label_names
    end
  end

  describe "build_index_key/1" do
    test "joins map values with dot separator" do
      assert TableLoader.build_index_key(%{"ifIndex" => 1}) == "1"
    end

    test "joins multiple values in the table index order" do
      indices = %{"ifIndex" => 1, "cmIndex" => 2}

      assert TableLoader.build_index_key(indices, ["ifIndex", "cmIndex"]) == "1.2"
    end
  end
end
