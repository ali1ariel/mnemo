defmodule MnemoWeb.SlotsLiveTest do
  use MnemoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mnemo.Drive.Fake
  alias Mnemo.{Games, RenPyFixtures}

  setup do
    Fake.reset()
    root = Path.join(System.tmp_dir!(), "mnemo-slots-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp enroll_with_saves!(root) do
    dir = Path.join(root, "MyGame-123")
    RenPyFixtures.write_save(dir, "1-Save Slot 2-LT1.save", save_name: "Before the boss")
    RenPyFixtures.write_save(dir, "1-Save Slot 10-LT1.save")
    RenPyFixtures.write_save(dir, "2-Save Slot 1-LT1.save")
    RenPyFixtures.write_save(dir, "auto-1-LT1.save")
    RenPyFixtures.write_save(dir, "quick-1-LT1.save")
    File.write!(Path.join(dir, "persistent"), "p")

    {:ok, game} =
      Games.enroll(%{save_directory: "MyGame-123", install_root: root, name: "My Game"})

    game
  end

  test "renders pages, autosaves and quicksaves in separate sections", %{conn: conn, root: root} do
    game = enroll_with_saves!(root)

    {:ok, view, html} = live(conn, ~p"/games/#{game.id}")

    assert html =~ "My Game"
    assert has_element?(view, "#page-1")
    assert has_element?(view, "#page-2")
    assert has_element?(view, "#autosaves")
    assert has_element?(view, "#quicksaves")
    assert has_element?(view, "#slot-1-Save-Slot-2-LT1-save")
    assert html =~ "Before the boss"
    assert html =~ "Autosave 1"
    assert html =~ "Quicksave 1"
    assert has_element?(view, "#sync-now")
  end

  test "slot names sort naturally within a page", %{conn: conn, root: root} do
    game = enroll_with_saves!(root)

    {:ok, _view, html} = live(conn, ~p"/games/#{game.id}")

    {pos_2, _} = :binary.match(html, "slot-1-Save-Slot-2-LT1-save")
    {pos_10, _} = :binary.match(html, "slot-1-Save-Slot-10-LT1-save")
    assert pos_2 < pos_10
  end

  test "screenshots render blurred behind a reveal toggle", %{conn: conn, root: root} do
    game = enroll_with_saves!(root)

    {:ok, view, _html} = live(conn, ~p"/games/#{game.id}")

    assert has_element?(view, "#slot-1-Save-Slot-2-LT1-save input[type=checkbox]")
    assert has_element?(view, "#slot-1-Save-Slot-2-LT1-save img.blur-xl")
    assert has_element?(view, "#slot-1-Save-Slot-2-LT1-save img[src*='/covers/#{game.id}/']")
  end

  test "a game with no slot saves shows the empty state", %{conn: conn, root: root} do
    dir = Path.join(root, "Fresh-1")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "persistent"), "p")
    {:ok, game} = Games.enroll(%{save_directory: "Fresh-1", install_root: root})

    {:ok, view, _html} = live(conn, ~p"/games/#{game.id}")
    assert has_element?(view, "#no-saves")
  end

  test "unknown and malformed ids navigate back to the library", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/games/#{Ecto.UUID.generate()}")
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/games/not-a-uuid")
  end
end
