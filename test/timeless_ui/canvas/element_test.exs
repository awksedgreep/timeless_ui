defmodule TimelessUI.Canvas.ElementTest do
  use ExUnit.Case, async: true

  alias TimelessUI.Canvas.Element

  describe "move/3" do
    test "moves element by dx, dy" do
      el = %Element{id: "1", x: 100.0, y: 200.0}
      result = Element.move(el, 50.0, -30.0)

      assert result.x == 150.0
      assert result.y == 170.0
    end
  end

  describe "resize/3" do
    test "resizes element" do
      el = %Element{id: "1", width: 160.0, height: 80.0}
      result = Element.resize(el, 200.0, 100.0)

      assert result.width == 200.0
      assert result.height == 100.0
    end

    test "enforces minimum 20x20" do
      el = %Element{id: "1", width: 160.0, height: 80.0}
      result = Element.resize(el, 5.0, 10.0)

      assert result.width == 20.0
      assert result.height == 20.0
    end
  end

  describe "new/1" do
    test "creates element with type defaults" do
      el = Element.new(%{id: "1", type: :server})

      assert el.type == :server
      assert el.width == 120.0
      assert el.height == 100.0
      assert el.color == "#6366f1"
    end

    test "caller attrs override type defaults" do
      el = Element.new(%{id: "1", type: :server, color: "#ff0000"})

      assert el.type == :server
      assert el.color == "#ff0000"
      assert el.width == 120.0
    end

    test "defaults to :rect type" do
      el = Element.new(%{id: "1"})

      assert el.type == :rect
      assert el.width == 160.0
    end
  end

  describe "element_types/0" do
    test "returns all registered types" do
      types = Element.element_types()

      assert :rect in types
      assert :server in types
      assert :database in types
      assert :service in types
      assert :load_balancer in types
      assert :queue in types
      assert :cache in types
      assert :network in types
      assert :graph in types
      assert :router in types
      assert :log_stream in types
      assert :trace_stream in types
      assert :canvas in types
      assert length(types) == 13
    end
  end

  describe "defaults_for/1" do
    test "returns defaults for known type" do
      defaults = Element.defaults_for(:database)

      assert defaults.width == 100.0
      assert defaults.height == 120.0
      assert defaults.color == "#f59e0b"
      assert defaults.type == :database
    end

    test "falls back to :rect for unknown type" do
      defaults = Element.defaults_for(:unknown)

      assert defaults.width == 160.0
      assert defaults.type == :unknown
    end
  end

  describe "meta_fields/1" do
    test "returns fields for server type" do
      fields = Element.meta_fields(:server)
      assert "host" in fields
      assert "ip" in fields
      assert "os" in fields
      assert "role" in fields
    end

    test "returns fields for database type" do
      fields = Element.meta_fields(:database)
      assert "engine" in fields
      assert "host" in fields
      assert "port" in fields
      assert "db_name" in fields
    end

    test "returns image_url for rect type" do
      assert Element.meta_fields(:rect) == ["image_url"]
    end

    test "returns empty list for unknown type" do
      assert Element.meta_fields(:unknown_type) == []
    end
  end

  describe "log_stream element type" do
    test "has wide panel dimensions" do
      el = Element.new(%{id: "1", type: :log_stream})
      assert el.width == 280.0
      assert el.height == 80.0
      assert el.color == "#10b981"
    end

    test "has level and metadata_filter meta fields" do
      fields = Element.meta_fields(:log_stream)
      assert "level" in fields
      assert "metadata_filter" in fields
    end
  end

  describe "trace_stream element type" do
    test "has wide panel dimensions" do
      el = Element.new(%{id: "1", type: :trace_stream})
      assert el.width == 280.0
      assert el.height == 80.0
      assert el.color == "#8b5cf6"
    end

    test "has service, name, and kind meta fields" do
      fields = Element.meta_fields(:trace_stream)
      assert "service" in fields
      assert "name" in fields
      assert "kind" in fields
    end
  end

  describe "graph element type" do
    test "has compact sparkline dimensions" do
      el = Element.new(%{id: "1", type: :graph})
      assert el.width == 120.0
      assert el.height == 60.0
      assert el.color == "#0ea5e9"
    end

    test "has metric_name meta field" do
      fields = Element.meta_fields(:graph)
      assert "metric_name" in fields
    end
  end

  describe "canvas element type" do
    test "has correct defaults" do
      defaults = Element.defaults_for(:canvas)
      assert defaults.width == 140.0
      assert defaults.height == 100.0
      assert defaults.color == "#818cf8"
      assert defaults.type == :canvas
    end

    test "creates element with type defaults" do
      el = Element.new(%{id: "1", type: :canvas})
      assert el.type == :canvas
      assert el.width == 140.0
      assert el.height == 100.0
      assert el.color == "#818cf8"
    end

    test "has canvas_id meta field" do
      fields = Element.meta_fields(:canvas)
      assert fields == ["canvas_id"]
    end
  end

  describe "status field" do
    test "defaults to :unknown" do
      el = Element.new(%{id: "1", type: :server})
      assert el.status == :unknown
    end
  end

  describe "snap_to_grid/2" do
    test "snaps to nearest grid point" do
      el = %Element{id: "1", x: 33.0, y: 47.0}
      result = Element.snap_to_grid(el, 20)

      assert result.x == 40.0
      assert result.y == 40.0
    end

    test "already on grid stays put" do
      el = %Element{id: "1", x: 60.0, y: 80.0}
      result = Element.snap_to_grid(el, 20)

      assert result.x == 60.0
      assert result.y == 80.0
    end
  end
end
