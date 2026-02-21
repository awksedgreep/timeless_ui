defmodule TimelessUI.Canvases.PolicyTest do
  use TimelessUI.DataCase

  alias TimelessUI.Canvases
  alias TimelessUI.Canvases.Policy
  alias TimelessUI.Canvas.Serializer
  alias TimelessUI.Canvas

  import TimelessUI.AccountsFixtures

  setup do
    owner = user_fixture()
    editor = user_fixture()
    viewer = user_fixture()
    outsider = user_fixture()

    {:ok, canvas} = Canvases.save_canvas(owner.id, "test", Serializer.encode(Canvas.new()))
    {:ok, _} = Canvases.grant_access(canvas.id, editor.id, :editor)
    {:ok, _} = Canvases.grant_access(canvas.id, viewer.id, :viewer)

    %{canvas: canvas, owner: owner, editor: editor, viewer: viewer, outsider: outsider}
  end

  describe "admin?/1" do
    test "returns false when ADMIN_EMAILS not set", %{owner: owner} do
      System.delete_env("ADMIN_EMAILS")
      refute Policy.admin?(owner)
    end

    test "returns true when user email is in ADMIN_EMAILS", %{owner: owner} do
      System.put_env("ADMIN_EMAILS", owner.email)
      assert Policy.admin?(owner)
      System.delete_env("ADMIN_EMAILS")
    end

    test "handles comma-separated list", %{owner: owner} do
      System.put_env("ADMIN_EMAILS", "other@test.com,#{owner.email},another@test.com")
      assert Policy.admin?(owner)
      System.delete_env("ADMIN_EMAILS")
    end
  end

  describe "authorize/3 - owner" do
    test "owner can view", %{owner: owner, canvas: canvas} do
      assert :ok = Policy.authorize(owner, canvas, :view)
    end

    test "owner can edit", %{owner: owner, canvas: canvas} do
      assert :ok = Policy.authorize(owner, canvas, :edit)
    end

    test "owner can delete", %{owner: owner, canvas: canvas} do
      assert :ok = Policy.authorize(owner, canvas, :delete)
    end

    test "owner can share", %{owner: owner, canvas: canvas} do
      assert :ok = Policy.authorize(owner, canvas, :share)
    end
  end

  describe "authorize/3 - editor" do
    test "editor can view", %{editor: editor, canvas: canvas} do
      assert :ok = Policy.authorize(editor, canvas, :view)
    end

    test "editor can edit", %{editor: editor, canvas: canvas} do
      assert :ok = Policy.authorize(editor, canvas, :edit)
    end

    test "editor cannot delete", %{editor: editor, canvas: canvas} do
      assert {:error, :unauthorized} = Policy.authorize(editor, canvas, :delete)
    end

    test "editor cannot share", %{editor: editor, canvas: canvas} do
      assert {:error, :unauthorized} = Policy.authorize(editor, canvas, :share)
    end
  end

  describe "authorize/3 - viewer" do
    test "viewer can view", %{viewer: viewer, canvas: canvas} do
      assert :ok = Policy.authorize(viewer, canvas, :view)
    end

    test "viewer cannot edit", %{viewer: viewer, canvas: canvas} do
      assert {:error, :unauthorized} = Policy.authorize(viewer, canvas, :edit)
    end

    test "viewer cannot delete", %{viewer: viewer, canvas: canvas} do
      assert {:error, :unauthorized} = Policy.authorize(viewer, canvas, :delete)
    end
  end

  describe "authorize/3 - outsider" do
    test "outsider cannot view", %{outsider: outsider, canvas: canvas} do
      assert {:error, :unauthorized} = Policy.authorize(outsider, canvas, :view)
    end

    test "outsider cannot edit", %{outsider: outsider, canvas: canvas} do
      assert {:error, :unauthorized} = Policy.authorize(outsider, canvas, :edit)
    end
  end

  describe "authorize/3 - admin" do
    test "admin bypasses all checks", %{outsider: outsider, canvas: canvas} do
      System.put_env("ADMIN_EMAILS", outsider.email)

      assert :ok = Policy.authorize(outsider, canvas, :view)
      assert :ok = Policy.authorize(outsider, canvas, :edit)
      assert :ok = Policy.authorize(outsider, canvas, :delete)
      assert :ok = Policy.authorize(outsider, canvas, :share)

      System.delete_env("ADMIN_EMAILS")
    end
  end
end
