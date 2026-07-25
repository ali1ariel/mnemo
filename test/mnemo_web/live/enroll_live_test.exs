defmodule MnemoWeb.EnrollLiveTest do
  use MnemoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mnemo.Drive.Fake
  alias Mnemo.{Games, RenPyFixtures}

  setup do
    Fake.reset()
    root = Path.join(System.tmp_dir!(), "mnemo-enroll-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Application.put_env(:mnemo, :renpy_roots, [root])

    on_exit(fn ->
      Application.put_env(:mnemo, :renpy_roots, [])
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "scans the roots and lists found games with a preview", %{conn: conn, root: root} do
    RenPyFixtures.write_save(Path.join(root, "SomeGame-1"), "1-1-LT1.save")

    {:ok, view, _html} = live(conn, ~p"/enroll")
    html = render_async(view)

    assert html =~ "Some Game"
    assert html =~ "data:image/png;base64,"
    assert has_element?(view, "#enroll-0")
  end

  test "enrolling a scanned game persists it and navigates to the library",
       %{conn: conn, root: root} do
    RenPyFixtures.write_save(Path.join(root, "SomeGame-1"), "1-1-LT1.save")

    {:ok, view, _html} = live(conn, ~p"/enroll")
    render_async(view)

    view |> element("#enroll-0") |> render_click()
    assert_redirect(view, "/")

    assert [game] = Games.list()
    assert game.save_directory == "SomeGame-1"
    assert game.install_root == "appdata"
    assert game.name == "Some Game"
  end

  test "already enrolled games show a badge instead of the enroll button",
       %{conn: conn, root: root} do
    RenPyFixtures.write_save(Path.join(root, "SomeGame-1"), "1-1-LT1.save")
    {:ok, _game} = Games.enroll(%{save_directory: "SomeGame-1", install_root: "appdata"})

    {:ok, view, _html} = live(conn, ~p"/enroll")
    html = render_async(view)

    assert html =~ "Enrolled"
    refute has_element?(view, "#enroll-0")
  end

  test "shows the empty state when nothing is found", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/enroll")
    render_async(view)
    assert has_element?(view, "#scan-empty")
  end

  test "previews a game's saves before enrolling", %{conn: conn, root: root} do
    dir = Path.join(root, "SomeGame-1")
    RenPyFixtures.write_save(dir, "1-Save Slot 2-LT1.save", save_name: "Before the boss")
    RenPyFixtures.write_save(dir, "auto-1-LT1.save")

    {:ok, view, _html} = live(conn, ~p"/enroll")
    render_async(view)

    view |> element("#preview-0") |> render_click()

    assert has_element?(view, "#scan-entry-saves-0")
    assert has_element?(view, "#page-1")
    assert has_element?(view, "#autosaves")
    assert has_element?(view, "#slot-1-Save-Slot-2-LT1-save img[src*='/scan/preview']")
    assert has_element?(view, "#slot-1-Save-Slot-2-LT1-save input[type=checkbox]")
    assert render(view) =~ "Before the boss"

    view |> element("#preview-0") |> render_click()
    refute has_element?(view, "#scan-entry-saves-0")
  end

  test "previewing a folder whose saves vanished shows a hint", %{conn: conn, root: root} do
    dir = Path.join(root, "SomeGame-1")
    save = RenPyFixtures.write_save(dir, "1-1-LT1.save")

    {:ok, view, _html} = live(conn, ~p"/enroll")
    render_async(view)

    File.rm!(save)
    view |> element("#preview-0") |> render_click()

    assert has_element?(view, "#scan-entry-saves-0")
    assert render(view) =~ "No save slots here yet."
  end
end
