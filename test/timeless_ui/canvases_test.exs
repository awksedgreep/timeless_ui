defmodule TimelessUI.CanvasesTest do
  use TimelessUI.DataCase

  alias TimelessUI.Canvases
  alias TimelessUI.Canvas
  alias TimelessUI.Canvas.Serializer

  describe "save_canvas/2" do
    test "inserts a new canvas" do
      data = Serializer.encode(Canvas.new())
      assert {:ok, record} = Canvases.save_canvas("test_canvas", data)
      assert record.name == "test_canvas"
      assert record.data["version"] == 1
    end

    test "updates existing canvas on upsert" do
      data1 = Serializer.encode(Canvas.new())
      {:ok, _} = Canvases.save_canvas("upsert_test", data1)

      {canvas, _el} = Canvas.add_element(Canvas.new(), %{type: :server, x: 100.0, y: 200.0})
      data2 = Serializer.encode(canvas)
      {:ok, record} = Canvases.save_canvas("upsert_test", data2)

      assert record.name == "upsert_test"
      assert map_size(record.data["elements"]) == 1
    end
  end

  describe "get_canvas/1" do
    test "returns {:ok, record} for existing canvas" do
      data = Serializer.encode(Canvas.new())
      {:ok, _} = Canvases.save_canvas("get_test", data)

      assert {:ok, record} = Canvases.get_canvas("get_test")
      assert record.name == "get_test"
    end

    test "returns {:error, :not_found} for missing canvas" do
      assert {:error, :not_found} = Canvases.get_canvas("nonexistent")
    end
  end

  describe "round-trip save/load" do
    test "canvas survives encode -> save -> load -> decode" do
      canvas = Canvas.new()
      {canvas, _el} = Canvas.add_element(canvas, %{type: :server, x: 50.0, y: 75.0, label: "Web"})
      {canvas, _el} = Canvas.add_element(canvas, %{type: :database, x: 300.0, y: 75.0, label: "DB"})

      data = Serializer.encode(canvas)
      {:ok, _} = Canvases.save_canvas("roundtrip", data)

      {:ok, record} = Canvases.get_canvas("roundtrip")
      {:ok, loaded} = Serializer.decode(record.data)

      assert map_size(loaded.elements) == 2
      assert loaded.next_id == canvas.next_id
    end
  end

  describe "list_canvases/0" do
    test "returns canvas names in order" do
      data = Serializer.encode(Canvas.new())
      {:ok, _} = Canvases.save_canvas("beta", data)
      {:ok, _} = Canvases.save_canvas("alpha", data)

      names = Canvases.list_canvases()
      assert names == ["alpha", "beta"]
    end
  end

  describe "delete_canvas/1" do
    test "deletes existing canvas" do
      data = Serializer.encode(Canvas.new())
      {:ok, _} = Canvases.save_canvas("doomed", data)

      assert {:ok, _} = Canvases.delete_canvas("doomed")
      assert {:error, :not_found} = Canvases.get_canvas("doomed")
    end

    test "returns error for missing canvas" do
      assert {:error, :not_found} = Canvases.delete_canvas("ghost")
    end
  end
end
