defmodule TimelessUI.Canvas.SerializerTest do
  use ExUnit.Case, async: true

  alias TimelessUI.Canvas
  alias TimelessUI.Canvas.Serializer

  describe "encode/1 and decode/1 roundtrip" do
    test "empty canvas roundtrips" do
      canvas = Canvas.new()
      data = Serializer.encode(canvas)
      {:ok, decoded} = Serializer.decode(data)

      assert decoded.view_box == canvas.view_box
      assert decoded.elements == %{}
      assert decoded.connections == %{}
      assert decoded.grid_size == canvas.grid_size
      assert decoded.next_id == canvas.next_id
    end

    test "canvas with elements roundtrips" do
      canvas = Canvas.new(snap_to_grid: false)

      {canvas, _} =
        Canvas.add_element(canvas, %{label: "Server", type: :server, x: 100.0, y: 200.0})

      {canvas, _} =
        Canvas.add_element(canvas, %{label: "DB", type: :database, x: 300.0, y: 400.0})

      data = Serializer.encode(canvas)
      {:ok, decoded} = Serializer.decode(data)

      assert map_size(decoded.elements) == 2
      assert decoded.elements["el-1"].label == "Server"
      assert decoded.elements["el-1"].type == :server
      assert decoded.elements["el-2"].label == "DB"
      assert decoded.elements["el-2"].type == :database
      assert decoded.next_id == 3
    end

    test "canvas with connections roundtrips" do
      canvas = Canvas.new(snap_to_grid: false)
      {canvas, el1} = Canvas.add_element(canvas, %{label: "A"})
      {canvas, el2} = Canvas.add_element(canvas, %{label: "B"})

      {canvas, _} =
        Canvas.add_connection(canvas, el1.id, el2.id, %{label: "conn", style: :dashed})

      data = Serializer.encode(canvas)
      {:ok, decoded} = Serializer.decode(data)

      assert map_size(decoded.connections) == 1
      conn = decoded.connections["conn-1"]
      assert conn.label == "conn"
      assert conn.style == :dashed
      assert conn.source_id == el1.id
      assert conn.target_id == el2.id
    end

    test "preserves view_box" do
      canvas = Canvas.new() |> Canvas.pan(100.0, 50.0) |> Canvas.zoom(600.0, 400.0, 0.5)
      data = Serializer.encode(canvas)
      {:ok, decoded} = Serializer.decode(data)

      assert_in_delta decoded.view_box.min_x, canvas.view_box.min_x, 0.01
      assert_in_delta decoded.view_box.min_y, canvas.view_box.min_y, 0.01
      assert_in_delta decoded.view_box.width, canvas.view_box.width, 0.01
    end

    test "preserves grid settings" do
      canvas = Canvas.new(grid_size: 10, grid_visible: false, snap_to_grid: false)
      data = Serializer.encode(canvas)
      {:ok, decoded} = Serializer.decode(data)

      assert decoded.grid_size == 10
      assert decoded.grid_visible == false
      assert decoded.snap_to_grid == false
    end
  end

  describe "decode/1 error handling" do
    test "rejects unsupported version" do
      assert {:error, "unsupported version"} = Serializer.decode(%{"version" => 99})
    end

    test "rejects non-map input" do
      assert {:error, "unsupported version"} = Serializer.decode("not a map")
    end

    test "handles unknown element type gracefully" do
      data = %{
        "version" => 1,
        "elements" => %{
          "el-1" => %{
            "id" => "el-1",
            "type" => "totally_unknown_type_xyz",
            "x" => 0,
            "y" => 0,
            "width" => 100,
            "height" => 50,
            "label" => "test"
          }
        }
      }

      {:ok, decoded} = Serializer.decode(data)
      # Falls back to :rect for unknown type
      assert decoded.elements["el-1"].type == :rect
    end
  end
end
