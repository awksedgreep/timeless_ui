defmodule TimelessUI.Canvas.ViewBoxTest do
  use ExUnit.Case, async: true

  alias TimelessUI.Canvas.ViewBox

  describe "to_string/1" do
    test "formats viewbox for SVG attribute" do
      vb = %ViewBox{min_x: 10.0, min_y: 20.0, width: 800.0, height: 600.0}
      assert ViewBox.to_string(vb) == "10.0 20.0 800.0 600.0"
    end

    test "formats default viewbox" do
      assert ViewBox.to_string(%ViewBox{}) == "0.0 0.0 1200.0 800.0"
    end
  end

  describe "pan/3" do
    test "translates by dx, dy" do
      vb = %ViewBox{min_x: 0.0, min_y: 0.0, width: 1200.0, height: 800.0}
      result = ViewBox.pan(vb, 50.0, -30.0)

      assert result.min_x == 50.0
      assert result.min_y == -30.0
      assert result.width == 1200.0
      assert result.height == 800.0
    end
  end

  describe "zoom/4" do
    test "zoom in (factor < 1) narrows viewbox" do
      vb = %ViewBox{min_x: 0.0, min_y: 0.0, width: 1200.0, height: 800.0}
      result = ViewBox.zoom(vb, 600.0, 400.0, 0.9)

      assert result.width < vb.width
      assert result.height < vb.height
    end

    test "zoom out (factor > 1) widens viewbox" do
      vb = %ViewBox{min_x: 0.0, min_y: 0.0, width: 1200.0, height: 800.0}
      result = ViewBox.zoom(vb, 600.0, 400.0, 1.1)

      assert result.width > vb.width
      assert result.height > vb.height
    end

    test "cursor point stays stationary after zoom" do
      vb = %ViewBox{min_x: 100.0, min_y: 50.0, width: 1200.0, height: 800.0}
      cx = 400.0
      cy = 300.0

      result = ViewBox.zoom(vb, cx, cy, 0.8)

      # The fraction of the viewbox that cx represents should stay the same
      old_frac_x = (cx - vb.min_x) / vb.width
      new_frac_x = (cx - result.min_x) / result.width

      assert_in_delta old_frac_x, new_frac_x, 0.001
    end

    test "refuses to zoom below minimum width" do
      vb = %ViewBox{min_x: 0.0, min_y: 0.0, width: 120.0, height: 80.0}
      result = ViewBox.zoom(vb, 60.0, 40.0, 0.5)

      # Should not change since 120 * 0.5 = 60 < 100
      assert result == vb
    end

    test "refuses to zoom above maximum width" do
      vb = %ViewBox{min_x: 0.0, min_y: 0.0, width: 45_000.0, height: 30_000.0}
      result = ViewBox.zoom(vb, 0.0, 0.0, 1.5)

      # 45000 * 1.5 = 67500 > 50000
      assert result == vb
    end
  end

  describe "client_to_svg/5" do
    test "converts pixel coordinates to SVG coordinates" do
      vb = %ViewBox{min_x: 0.0, min_y: 0.0, width: 1200.0, height: 800.0}
      {svg_x, svg_y} = ViewBox.client_to_svg(vb, 600.0, 400.0, 1200.0, 800.0)

      assert_in_delta svg_x, 600.0, 0.01
      assert_in_delta svg_y, 400.0, 0.01
    end

    test "accounts for viewbox offset" do
      vb = %ViewBox{min_x: 100.0, min_y: 200.0, width: 1200.0, height: 800.0}
      {svg_x, svg_y} = ViewBox.client_to_svg(vb, 0.0, 0.0, 1200.0, 800.0)

      assert_in_delta svg_x, 100.0, 0.01
      assert_in_delta svg_y, 200.0, 0.01
    end

    test "handles zoomed viewbox (client smaller than SVG)" do
      vb = %ViewBox{min_x: 0.0, min_y: 0.0, width: 2400.0, height: 1600.0}
      # Client is 1200px wide but viewbox is 2400 SVG units
      {svg_x, _svg_y} = ViewBox.client_to_svg(vb, 600.0, 400.0, 1200.0, 800.0)

      assert_in_delta svg_x, 1200.0, 0.01
    end
  end
end
