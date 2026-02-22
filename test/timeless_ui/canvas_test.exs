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

  describe "move_elements/4" do
    test "moves multiple elements by delta" do
      canvas = Canvas.new(snap_to_grid: false)
      {canvas, el1} = Canvas.add_element(canvas, %{x: 100.0, y: 100.0})
      {canvas, el2} = Canvas.add_element(canvas, %{x: 300.0, y: 200.0})

      canvas = Canvas.move_elements(canvas, [el1.id, el2.id], 50.0, -25.0)

      assert canvas.elements[el1.id].x == 150.0
      assert canvas.elements[el1.id].y == 75.0
      assert canvas.elements[el2.id].x == 350.0
      assert canvas.elements[el2.id].y == 175.0
    end

    test "skips non-existent IDs" do
      canvas = Canvas.new(snap_to_grid: false)
      {canvas, el} = Canvas.add_element(canvas, %{x: 100.0, y: 100.0})

      canvas = Canvas.move_elements(canvas, [el.id, "nope"], 10.0, 10.0)

      assert canvas.elements[el.id].x == 110.0
      assert canvas.elements[el.id].y == 110.0
    end

    test "returns unchanged canvas for empty list" do
      canvas = Canvas.new()
      assert Canvas.move_elements(canvas, [], 50.0, 50.0) == canvas
    end
  end

  describe "remove_elements/2" do
    test "removes multiple elements and their connections" do
      canvas = Canvas.new()
      {canvas, el1} = Canvas.add_element(canvas)
      {canvas, el2} = Canvas.add_element(canvas)
      {canvas, el3} = Canvas.add_element(canvas)
      {canvas, _conn} = Canvas.add_connection(canvas, el1.id, el2.id)
      {canvas, _conn2} = Canvas.add_connection(canvas, el2.id, el3.id)

      canvas = Canvas.remove_elements(canvas, [el1.id, el2.id])

      assert map_size(canvas.elements) == 1
      assert Map.has_key?(canvas.elements, el3.id)
      # All connections involving el1 or el2 should be gone
      assert canvas.connections == %{}
    end

    test "returns unchanged canvas for empty list" do
      canvas = Canvas.new()
      {canvas, _el} = Canvas.add_element(canvas)
      original = canvas

      assert Canvas.remove_elements(canvas, []) == original
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

  describe "duplicate_elements/3" do
    test "duplicates a single element with new ID and offset" do
      canvas = Canvas.new(snap_to_grid: false)

      {canvas, el} =
        Canvas.add_element(canvas, %{
          type: :server,
          x: 100.0,
          y: 200.0,
          label: "Web",
          color: "#ff0000",
          meta: %{"host" => "srv1"}
        })

      {canvas, new_ids} = Canvas.duplicate_elements(canvas, [el], 20)

      assert length(new_ids) == 1
      [new_id] = new_ids
      assert new_id != el.id
      new_el = canvas.elements[new_id]
      assert new_el.x == 120.0
      assert new_el.y == 220.0
      assert new_el.type == :server
      assert new_el.label == "Web"
      assert new_el.color == "#ff0000"
      assert new_el.meta == %{"host" => "srv1"}
    end

    test "duplicates multiple elements with unique IDs" do
      canvas = Canvas.new(snap_to_grid: false)
      {canvas, el1} = Canvas.add_element(canvas, %{x: 100.0, y: 100.0, label: "A"})
      {canvas, el2} = Canvas.add_element(canvas, %{x: 300.0, y: 300.0, label: "B"})

      {canvas, new_ids} = Canvas.duplicate_elements(canvas, [el1, el2], 20)

      assert length(new_ids) == 2
      assert length(Enum.uniq(new_ids)) == 2
      assert Enum.all?(new_ids, &(&1 != el1.id and &1 != el2.id))
      assert map_size(canvas.elements) == 4

      [id1, id2] = new_ids
      assert canvas.elements[id1].x == 120.0
      assert canvas.elements[id2].x == 320.0
    end

    test "returns unchanged canvas for empty list" do
      canvas = Canvas.new()
      {result, new_ids} = Canvas.duplicate_elements(canvas, [], 20)

      assert result == canvas
      assert new_ids == []
    end

    test "resets status to :unknown on copies" do
      canvas = Canvas.new(snap_to_grid: false)
      {canvas, el} = Canvas.add_element(canvas, %{x: 0.0, y: 0.0})
      canvas = Canvas.set_element_status(canvas, el.id, :error)
      assert canvas.elements[el.id].status == :error

      {canvas, [new_id]} = Canvas.duplicate_elements(canvas, [canvas.elements[el.id]], 20)

      assert canvas.elements[new_id].status == :unknown
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
