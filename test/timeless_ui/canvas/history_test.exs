defmodule TimelessUI.Canvas.HistoryTest do
  use ExUnit.Case, async: true

  alias TimelessUI.Canvas
  alias TimelessUI.Canvas.History

  defp canvas_with_element(label) do
    canvas = Canvas.new()
    {canvas, _el} = Canvas.add_element(canvas, %{label: label})
    canvas
  end

  describe "new/1" do
    test "creates history with canvas as present" do
      canvas = Canvas.new()
      history = History.new(canvas)

      assert history.present == canvas
      assert history.past == []
      assert history.future == []
      assert history.max_size == 50
    end

    test "accepts max_size option" do
      history = History.new(Canvas.new(), max_size: 10)
      assert history.max_size == 10
    end
  end

  describe "push/2" do
    test "pushes current present to past" do
      canvas1 = Canvas.new()
      canvas2 = canvas_with_element("A")
      history = History.new(canvas1) |> History.push(canvas2)

      assert history.present == canvas2
      assert history.past == [canvas1]
      assert history.future == []
    end

    test "clears future on push" do
      canvas1 = Canvas.new()
      canvas2 = canvas_with_element("A")
      canvas3 = canvas_with_element("B")

      history =
        History.new(canvas1)
        |> History.push(canvas2)
        |> History.push(canvas3)
        |> History.undo()

      # Now future has canvas3
      assert history.future != []

      # Push new state - future should be cleared
      canvas4 = canvas_with_element("C")
      history = History.push(history, canvas4)
      assert history.future == []
      assert history.present == canvas4
    end

    test "trims past to max_size" do
      history = History.new(Canvas.new(), max_size: 3)

      history =
        Enum.reduce(1..5, history, fn i, h ->
          History.push(h, canvas_with_element("el-#{i}"))
        end)

      assert length(history.past) == 3
    end
  end

  describe "undo/1" do
    test "undoes to previous state" do
      canvas1 = Canvas.new()
      canvas2 = canvas_with_element("A")

      history =
        History.new(canvas1)
        |> History.push(canvas2)
        |> History.undo()

      assert history.present == canvas1
      assert history.past == []
      assert history.future == [canvas2]
    end

    test "does nothing when past is empty" do
      canvas = Canvas.new()
      history = History.new(canvas)
      result = History.undo(history)

      assert result == history
    end

    test "multiple undos walk back through history" do
      canvas1 = Canvas.new()
      canvas2 = canvas_with_element("A")
      canvas3 = canvas_with_element("B")

      history =
        History.new(canvas1)
        |> History.push(canvas2)
        |> History.push(canvas3)
        |> History.undo()
        |> History.undo()

      assert history.present == canvas1
      assert length(history.future) == 2
    end
  end

  describe "redo/1" do
    test "redoes to next state" do
      canvas1 = Canvas.new()
      canvas2 = canvas_with_element("A")

      history =
        History.new(canvas1)
        |> History.push(canvas2)
        |> History.undo()
        |> History.redo()

      assert history.present == canvas2
      assert history.future == []
      assert history.past == [canvas1]
    end

    test "does nothing when future is empty" do
      canvas = Canvas.new()
      history = History.new(canvas)
      result = History.redo(history)

      assert result == history
    end
  end

  describe "can_undo?/1 and can_redo?/1" do
    test "reports false on fresh history" do
      history = History.new(Canvas.new())
      refute History.can_undo?(history)
      refute History.can_redo?(history)
    end

    test "can_undo? true after push" do
      history = History.new(Canvas.new()) |> History.push(canvas_with_element("A"))
      assert History.can_undo?(history)
      refute History.can_redo?(history)
    end

    test "can_redo? true after undo" do
      history =
        History.new(Canvas.new())
        |> History.push(canvas_with_element("A"))
        |> History.undo()

      refute History.can_undo?(history)
      assert History.can_redo?(history)
    end
  end
end
