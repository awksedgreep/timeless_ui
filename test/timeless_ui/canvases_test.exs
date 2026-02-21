defmodule TimelessUI.CanvasesTest do
  use TimelessUI.DataCase

  alias TimelessUI.Canvases
  alias TimelessUI.Canvas
  alias TimelessUI.Canvas.Serializer

  import TimelessUI.AccountsFixtures

  setup do
    %{user: user_fixture()}
  end

  describe "save_canvas/3" do
    test "inserts a new canvas", %{user: user} do
      data = Serializer.encode(Canvas.new())
      assert {:ok, record} = Canvases.save_canvas(user.id, "test_canvas", data)
      assert record.name == "test_canvas"
      assert record.user_id == user.id
      assert record.data["version"] == 1
    end

    test "updates existing canvas on upsert", %{user: user} do
      data1 = Serializer.encode(Canvas.new())
      {:ok, _} = Canvases.save_canvas(user.id, "upsert_test", data1)

      {canvas, _el} = Canvas.add_element(Canvas.new(), %{type: :server, x: 100.0, y: 200.0})
      data2 = Serializer.encode(canvas)
      {:ok, record} = Canvases.save_canvas(user.id, "upsert_test", data2)

      assert record.name == "upsert_test"
      assert map_size(record.data["elements"]) == 1
    end

    test "different users can have same-named canvases", %{user: user} do
      user2 = user_fixture()
      data = Serializer.encode(Canvas.new())

      assert {:ok, _} = Canvases.save_canvas(user.id, "shared_name", data)
      assert {:ok, _} = Canvases.save_canvas(user2.id, "shared_name", data)
    end
  end

  describe "get_canvas/1" do
    test "returns {:ok, record} for existing canvas", %{user: user} do
      data = Serializer.encode(Canvas.new())
      {:ok, saved} = Canvases.save_canvas(user.id, "get_test", data)

      assert {:ok, record} = Canvases.get_canvas(saved.id)
      assert record.name == "get_test"
    end

    test "returns {:error, :not_found} for missing canvas" do
      assert {:error, :not_found} = Canvases.get_canvas(0)
    end
  end

  describe "create_canvas/2" do
    test "creates a canvas with empty data", %{user: user} do
      assert {:ok, record} = Canvases.create_canvas(user.id, "new_canvas")
      assert record.name == "new_canvas"
      assert record.user_id == user.id
      assert record.data == %{}
    end
  end

  describe "round-trip save/load" do
    test "canvas survives encode -> save -> load -> decode", %{user: user} do
      canvas = Canvas.new()
      {canvas, _el} = Canvas.add_element(canvas, %{type: :server, x: 50.0, y: 75.0, label: "Web"})
      {canvas, _el} = Canvas.add_element(canvas, %{type: :database, x: 300.0, y: 75.0, label: "DB"})

      data = Serializer.encode(canvas)
      {:ok, saved} = Canvases.save_canvas(user.id, "roundtrip", data)

      {:ok, record} = Canvases.get_canvas(saved.id)
      {:ok, loaded} = Serializer.decode(record.data)

      assert map_size(loaded.elements) == 2
      assert loaded.next_id == canvas.next_id
    end
  end

  describe "list_canvases_for_user/1" do
    test "returns canvases for user in order", %{user: user} do
      data = Serializer.encode(Canvas.new())
      {:ok, _} = Canvases.save_canvas(user.id, "beta", data)
      {:ok, _} = Canvases.save_canvas(user.id, "alpha", data)

      canvases = Canvases.list_canvases_for_user(user.id)
      assert length(canvases) == 2
      assert Enum.map(canvases, & &1.name) == ["alpha", "beta"]
    end

    test "does not return other users' canvases", %{user: user} do
      user2 = user_fixture()
      data = Serializer.encode(Canvas.new())
      {:ok, _} = Canvases.save_canvas(user.id, "mine", data)
      {:ok, _} = Canvases.save_canvas(user2.id, "theirs", data)

      canvases = Canvases.list_canvases_for_user(user.id)
      assert length(canvases) == 1
      assert hd(canvases).name == "mine"
    end
  end

  describe "delete_canvas/2" do
    test "deletes existing canvas owned by user", %{user: user} do
      data = Serializer.encode(Canvas.new())
      {:ok, saved} = Canvases.save_canvas(user.id, "doomed", data)

      assert {:ok, _} = Canvases.delete_canvas(saved.id, user.id)
      assert {:error, :not_found} = Canvases.get_canvas(saved.id)
    end

    test "returns error when user doesn't own canvas", %{user: user} do
      user2 = user_fixture()
      data = Serializer.encode(Canvas.new())
      {:ok, saved} = Canvases.save_canvas(user.id, "not_yours", data)

      assert {:error, :not_found} = Canvases.delete_canvas(saved.id, user2.id)
      # Canvas still exists
      assert {:ok, _} = Canvases.get_canvas(saved.id)
    end

    test "returns error for missing canvas", %{user: user} do
      assert {:error, :not_found} = Canvases.delete_canvas(0, user.id)
    end
  end

  describe "update_canvas_data/2" do
    test "updates data for existing canvas", %{user: user} do
      data1 = Serializer.encode(Canvas.new())
      {:ok, saved} = Canvases.save_canvas(user.id, "autosave", data1)

      {canvas, _el} = Canvas.add_element(Canvas.new(), %{type: :server, x: 100.0, y: 200.0})
      data2 = Serializer.encode(canvas)

      assert {:ok, updated} = Canvases.update_canvas_data(saved.id, data2)
      assert map_size(updated.data["elements"]) == 1
    end

    test "returns error for missing canvas" do
      assert {:error, :not_found} = Canvases.update_canvas_data(0, %{})
    end
  end

  describe "access management" do
    test "grant_access/3 creates access entry", %{user: user} do
      user2 = user_fixture()
      data = Serializer.encode(Canvas.new())
      {:ok, canvas} = Canvases.save_canvas(user.id, "shared", data)

      assert {:ok, access} = Canvases.grant_access(canvas.id, user2.id, :editor)
      assert access.role == :editor
    end

    test "grant_access/3 upserts role on conflict", %{user: user} do
      user2 = user_fixture()
      data = Serializer.encode(Canvas.new())
      {:ok, canvas} = Canvases.save_canvas(user.id, "shared", data)

      {:ok, _} = Canvases.grant_access(canvas.id, user2.id, :viewer)
      {:ok, updated} = Canvases.grant_access(canvas.id, user2.id, :editor)
      assert updated.role == :editor
    end

    test "revoke_access/2 removes access", %{user: user} do
      user2 = user_fixture()
      data = Serializer.encode(Canvas.new())
      {:ok, canvas} = Canvases.save_canvas(user.id, "shared", data)

      {:ok, _} = Canvases.grant_access(canvas.id, user2.id, :editor)
      assert {:ok, _} = Canvases.revoke_access(canvas.id, user2.id)
      assert {:error, :not_found} = Canvases.revoke_access(canvas.id, user2.id)
    end

    test "list_access/1 returns access entries with users", %{user: user} do
      user2 = user_fixture()
      data = Serializer.encode(Canvas.new())
      {:ok, canvas} = Canvases.save_canvas(user.id, "shared", data)

      {:ok, _} = Canvases.grant_access(canvas.id, user2.id, :viewer)

      accesses = Canvases.list_access(canvas.id)
      assert length(accesses) == 1
      assert hd(accesses).user.email == user2.email
    end

    test "list_accessible_canvases/1 includes owned and shared", %{user: user} do
      user2 = user_fixture()
      data = Serializer.encode(Canvas.new())

      {:ok, _owned} = Canvases.save_canvas(user.id, "mine", data)
      {:ok, shared} = Canvases.save_canvas(user2.id, "theirs", data)
      {:ok, _} = Canvases.grant_access(shared.id, user.id, :viewer)

      canvases = Canvases.list_accessible_canvases(user)
      names = Enum.map(canvases, & &1.name)
      assert "mine" in names
      assert "theirs" in names
    end
  end
end
