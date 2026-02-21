defmodule TimelessUI.CanvasTest do
  use ExUnit.Case, async: true

  alias TimelessUI.Canvas

  describe "new/1" do
    test "creates canvas with defaults" do
      canvas = Canvas.new()

      assert canvas.view_box.width == 1200.0
      assert canvas.elements == %{}
      assert canvas.grid_size == 20
      assert canvas.grid_visible == true
      assert canvas.snap_to_grid == true
      assert canvas.next_id == 1
    end

    test "accepts overrides" do
      canvas = Canvas.new(grid_size: 10, snap_to_grid: false)

      assert canvas.grid_size == 10
      assert canvas.snap_to_grid == false
    end
  end

  describe "add_element/2" do
    test "adds element with auto-incrementing ID" do
      canvas = Canvas.new()
      {canvas, el1} = Canvas.add_element(canvas, %{label: "A"})
      {canvas, el2} = Canvas.add_element(canvas, %{label: "B"})

      assert el1.id == "el-1"
      assert el2.id == "el-2"
      assert map_size(canvas.elements) == 2
      assert canvas.next_id == 3
    end

    test "snaps to grid when snap is enabled" do
      canvas = Canvas.new(snap_to_grid: true, grid_size: 20)
      {_canvas, el} = Canvas.add_element(canvas, %{x: 33.0, y: 47.0})

      assert el.x == 40.0
      assert el.y == 40.0
    end

    test "does not snap when snap is disabled" do
      canvas = Canvas.new(snap_to_grid: false)
      {_canvas, el} = Canvas.add_element(canvas, %{x: 33.0, y: 47.0})

      assert el.x == 33.0
      assert el.y == 47.0
    end
  end

  describe "move_element/4" do
    test "moves existing element" do
      canvas = Canvas.new(snap_to_grid: false)
      {canvas, el} = Canvas.add_element(canvas, %{x: 100.0, y: 200.0})

      canvas = Canvas.move_element(canvas, el.id, 50.0, -30.0)
      moved = canvas.elements[el.id]

      assert moved.x == 150.0
      assert moved.y == 170.0
    end

    test "ignores non-existent element" do
      canvas = Canvas.new()
      result = Canvas.move_element(canvas, "nope", 50.0, 50.0)

      assert result == canvas
    end
  end

  describe "resize_element/4" do
    test "resizes existing element" do
      canvas = Canvas.new()
      {canvas, el} = Canvas.add_element(canvas)

      canvas = Canvas.resize_element(canvas, el.id, 300.0, 150.0)
      resized = canvas.elements[el.id]

      assert resized.width == 300.0
      assert resized.height == 150.0
    end
  end

  describe "remove_element/2" do
    test "removes element by ID" do
      canvas = Canvas.new()
      {canvas, el} = Canvas.add_element(canvas)

      canvas = Canvas.remove_element(canvas, el.id)

      assert canvas.elements == %{}
    end
  end

  describe "update_element/3" do
    test "updates element attributes" do
      canvas = Canvas.new(snap_to_grid: false)
      {canvas, el} = Canvas.add_element(canvas, %{label: "Old"})

      canvas = Canvas.update_element(canvas, el.id, %{label: "New", color: "#ff0000"})
      updated = canvas.elements[el.id]

      assert updated.label == "New"
      assert updated.color == "#ff0000"
    end

    test "ignores non-existent element" do
      canvas = Canvas.new()
      result = Canvas.update_element(canvas, "nope", %{label: "New"})
      assert result == canvas
    end
  end

  describe "add_element/2 with types" do
    test "applies type defaults via Element.new" do
      canvas = Canvas.new(snap_to_grid: false)
      {_canvas, el} = Canvas.add_element(canvas, %{type: :server})

      assert el.type == :server
      assert el.width == 120.0
      assert el.height == 100.0
      assert el.color == "#6366f1"
    end
  end

  describe "pan/3" do
    test "pans the viewbox" do
      canvas = Canvas.new()
      canvas = Canvas.pan(canvas, 100.0, -50.0)

      assert canvas.view_box.min_x == 100.0
      assert canvas.view_box.min_y == -50.0
    end
  end

  describe "zoom/4" do
    test "zooms the viewbox" do
      canvas = Canvas.new()
      canvas = Canvas.zoom(canvas, 600.0, 400.0, 0.9)

      assert canvas.view_box.width < 1200.0
    end
  end
end
