defmodule TimelessUI.Canvas.ConnectionTest do
  use ExUnit.Case, async: true

  alias TimelessUI.Canvas

  defp canvas_with_two_elements do
    canvas = Canvas.new(snap_to_grid: false)
    {canvas, el1} = Canvas.add_element(canvas, %{label: "A", x: 0.0, y: 0.0})
    {canvas, el2} = Canvas.add_element(canvas, %{label: "B", x: 200.0, y: 200.0})
    {canvas, el1, el2}
  end

  describe "add_connection/4" do
    test "creates connection between two elements" do
      {canvas, el1, el2} = canvas_with_two_elements()
      {canvas, conn} = Canvas.add_connection(canvas, el1.id, el2.id)

      assert conn.id == "conn-1"
      assert conn.source_id == el1.id
      assert conn.target_id == el2.id
      assert conn.style == :solid
      assert map_size(canvas.connections) == 1
      assert canvas.next_conn_id == 2
    end

    test "returns nil connection when source doesn't exist" do
      {canvas, _el1, el2} = canvas_with_two_elements()
      {canvas2, conn} = Canvas.add_connection(canvas, "el-999", el2.id)

      assert conn == nil
      assert canvas2 == canvas
    end

    test "returns nil connection when target doesn't exist" do
      {canvas, el1, _el2} = canvas_with_two_elements()
      {canvas2, conn} = Canvas.add_connection(canvas, el1.id, "el-999")

      assert conn == nil
      assert canvas2 == canvas
    end

    test "accepts custom attributes" do
      {canvas, el1, el2} = canvas_with_two_elements()

      {_canvas, conn} =
        Canvas.add_connection(canvas, el1.id, el2.id, %{label: "HTTP", style: :dashed})

      assert conn.label == "HTTP"
      assert conn.style == :dashed
    end

    test "auto-increments connection IDs" do
      {canvas, el1, el2} = canvas_with_two_elements()
      {canvas, conn1} = Canvas.add_connection(canvas, el1.id, el2.id)
      {_canvas, conn2} = Canvas.add_connection(canvas, el2.id, el1.id)

      assert conn1.id == "conn-1"
      assert conn2.id == "conn-2"
    end
  end

  describe "remove_connection/2" do
    test "removes connection by ID" do
      {canvas, el1, el2} = canvas_with_two_elements()
      {canvas, conn} = Canvas.add_connection(canvas, el1.id, el2.id)

      canvas = Canvas.remove_connection(canvas, conn.id)
      assert canvas.connections == %{}
    end
  end

  describe "update_connection/3" do
    test "updates connection attributes" do
      {canvas, el1, el2} = canvas_with_two_elements()
      {canvas, conn} = Canvas.add_connection(canvas, el1.id, el2.id)

      canvas = Canvas.update_connection(canvas, conn.id, %{label: "API", color: "#ff0000"})
      updated = canvas.connections[conn.id]

      assert updated.label == "API"
      assert updated.color == "#ff0000"
    end

    test "ignores non-existent connection" do
      canvas = Canvas.new()
      result = Canvas.update_connection(canvas, "conn-999", %{label: "nope"})
      assert result == canvas
    end
  end

  describe "cascade delete" do
    test "removing element removes its connections" do
      {canvas, el1, el2} = canvas_with_two_elements()
      {canvas, _conn} = Canvas.add_connection(canvas, el1.id, el2.id)

      assert map_size(canvas.connections) == 1

      canvas = Canvas.remove_element(canvas, el1.id)
      assert canvas.connections == %{}
    end

    test "only removes connections touching the deleted element" do
      canvas = Canvas.new(snap_to_grid: false)
      {canvas, el1} = Canvas.add_element(canvas, %{label: "A"})
      {canvas, el2} = Canvas.add_element(canvas, %{label: "B"})
      {canvas, el3} = Canvas.add_element(canvas, %{label: "C"})

      {canvas, _c1} = Canvas.add_connection(canvas, el1.id, el2.id)
      {canvas, _c2} = Canvas.add_connection(canvas, el2.id, el3.id)
      {canvas, _c3} = Canvas.add_connection(canvas, el1.id, el3.id)

      assert map_size(canvas.connections) == 3

      # Remove el1 - should remove c1 and c3, keep c2
      canvas = Canvas.remove_element(canvas, el1.id)
      assert map_size(canvas.connections) == 1

      remaining = Map.values(canvas.connections) |> hd()
      assert remaining.source_id == el2.id
      assert remaining.target_id == el3.id
    end
  end

  describe "connections_for_element/2" do
    test "returns all connections touching an element" do
      canvas = Canvas.new(snap_to_grid: false)
      {canvas, el1} = Canvas.add_element(canvas, %{label: "A"})
      {canvas, el2} = Canvas.add_element(canvas, %{label: "B"})
      {canvas, el3} = Canvas.add_element(canvas, %{label: "C"})

      {canvas, _} = Canvas.add_connection(canvas, el1.id, el2.id)
      {canvas, _} = Canvas.add_connection(canvas, el2.id, el3.id)
      {canvas, _} = Canvas.add_connection(canvas, el3.id, el1.id)

      conns = Canvas.connections_for_element(canvas, el1.id)
      assert length(conns) == 2
    end
  end
end
