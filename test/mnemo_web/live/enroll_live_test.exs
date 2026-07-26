defmodule MnemoWeb.EnrollLiveTest do
  use MnemoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mnemo.Drive.Fake
  alias Mnemo.Sync.Restore
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

  # A Steam or itch.io copy that has been launched and quit but never
  # saved: Ren'Py mirrors a `persistent` into both of the folders it keeps
  # for the game, and there is no `.save` anywhere yet to match them by.
  describe "a game installed but not yet played" do
    setup %{root: root} do
      install = Path.join(root, "Some Game")
      File.mkdir_p!(Path.join(install, "renpy"))
      File.mkdir_p!(Path.join([install, "game", "saves"]))
      File.write!(Path.join([install, "game", "saves", "persistent"]), "same game")

      user = Path.join(root, "SomeGame-1")
      File.mkdir_p!(user)
      File.write!(Path.join(user, "persistent"), "same game")

      Application.put_env(:mnemo, :install_dirs, [root])
      on_exit(fn -> Application.put_env(:mnemo, :install_dirs, []) end)

      {:ok, install: install}
    end

    test "lists once, with the install folder as a mirror", %{conn: conn, install: install} do
      {:ok, view, _html} = live(conn, ~p"/enroll")
      html = render_async(view)

      assert has_element?(view, "#scan-entry-0")
      refute has_element?(view, "#scan-entry-1")
      assert html =~ Path.join([install, "game", "saves"])
    end

    test "enrolling it keeps the user savedir and records where the game lives",
         %{conn: conn, install: install} do
      {:ok, view, _html} = live(conn, ~p"/enroll")
      render_async(view)

      view |> element("#enroll-0") |> render_click()
      assert_redirect(view, "/")

      assert [game] = Games.list()
      assert game.save_directory == "SomeGame-1"
      assert game.install_path == install
    end

    test "already enrolled through the install folder, it is not offered again",
         %{conn: conn, install: install} do
      {:ok, _game} =
        Games.enroll(%{
          save_directory: "saves",
          install_root: Path.join(install, "game"),
          install_path: install
        })

      {:ok, view, _html} = live(conn, ~p"/enroll")
      html = render_async(view)

      assert html =~ "Enrolled"
      refute has_element?(view, "#enroll-0")
    end
  end

  describe "enrolling by importing an archive" do
    setup %{root: root} do
      dir = Path.join(root, "SomeGame-1")
      # What a freshly installed game looks like: launched once, quit.
      RenPyFixtures.write_save(dir, "1-1-LT1.save", seed: "reference")
      File.write!(Path.join(dir, "persistent"), "reference")
      {:ok, dir: dir}
    end

    test "the screen explains what the reference save is for", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/enroll")
      html = render_async(view)

      assert has_element?(view, "#enroll-help")
      assert html =~ "mnemo never creates a save folder"
      assert html =~ "identify the folder"
      assert html =~ "published as a generation first"
    end

    test "every unenrolled game offers both enrol and import", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/enroll")
      render_async(view)

      assert has_element?(view, "#enroll-0")
      assert has_element?(view, "#import-0")
    end

    test "an enrolled game offers neither", %{conn: conn, root: root} do
      {:ok, _game} = Games.enroll(%{save_directory: "SomeGame-1", install_root: root})

      {:ok, view, _html} = live(conn, ~p"/enroll")
      render_async(view)

      refute has_element?(view, "#enroll-0")
      refute has_element?(view, "#import-0")
    end

    test "picking a zip previews it without enrolling anything", %{conn: conn, dir: dir} do
      {:ok, view, _html} = live(conn, ~p"/enroll")
      render_async(view)

      html = upload_archive(view, [{"1-2-LT1.save", [seed: "b", save_name: "chapter two"]}])

      assert has_element?(view, "#import-preview-0")
      assert html =~ "chapter two"
      assert html =~ "1 save will be written."

      # Nothing committed yet, on either side.
      assert Games.list() == []
      assert File.regular?(Path.join(dir, "1-1-LT1.save"))
    end

    test "confirming enrols the game and replaces the folder with the archive", %{
      conn: conn,
      dir: dir
    } do
      Mnemo.Game.subscribe()

      {:ok, view, _html} = live(conn, ~p"/enroll")
      render_async(view)

      upload_archive(view, [
        {"1-2-LT1.save", [seed: "b"]},
        {"1-3-LT1.save", [seed: "c"]}
      ])

      view |> form("#import-form-0", %{"confirmed" => "true"}) |> render_submit()

      assert [game] = Games.list()
      assert game.save_directory == "SomeGame-1"
      assert_redirect(view, "/games/#{game.id}")

      game_id = game.id
      assert_receive {:game, ^game_id, %{status: :imported}}, 5_000

      # The reference save is gone: it only ever identified the folder.
      assert File.ls!(dir) |> Enum.sort() == ["1-2-LT1.save", "1-3-LT1.save"]
    end

    test "the replaced saves stay recoverable from the history", %{conn: conn, dir: dir} do
      Mnemo.Game.subscribe()

      {:ok, view, _html} = live(conn, ~p"/enroll")
      render_async(view)

      upload_archive(view, [{"1-2-LT1.save", [seed: "b"]}])
      view |> form("#import-form-0", %{"confirmed" => "true"}) |> render_submit()

      assert [game] = Games.list()
      game_id = game.id
      assert_receive {:game, ^game_id, %{status: :imported}}, 5_000

      assert {:ok, _} =
               Restore.run(Games.get!(game.id), 1, confirmed_closed: true, force: true)

      assert File.read!(Path.join(dir, "persistent")) == "reference"
      assert File.regular?(Path.join(dir, "1-1-LT1.save"))
    end

    test "the import needs a confirmation that the game is closed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/enroll")
      render_async(view)

      upload_archive(view, [{"1-2-LT1.save", [seed: "b"]}])

      assert has_element?(view, "#import-form-0 input[name=confirmed][required]")
    end

    test "cancelling leaves the game unenrolled and the folder alone", %{conn: conn, dir: dir} do
      {:ok, view, _html} = live(conn, ~p"/enroll")
      render_async(view)

      upload_archive(view, [{"1-2-LT1.save", [seed: "b"]}])
      view |> element("#cancel-import-0") |> render_click()

      refute has_element?(view, "#import-panel-0")
      assert has_element?(view, "#import-0")
      assert Games.list() == []
      assert File.regular?(Path.join(dir, "1-1-LT1.save"))
    end

    test "a zip with no Ren'Py saves cannot be imported", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/enroll")
      render_async(view)

      upload_archive(view, [{"holiday.jpg", {:raw, "jpeg"}}])

      assert has_element?(view, "#import-nothing-0")
      refute has_element?(view, "#import-form-0")
    end
  end

  defp upload_archive(view, members, name \\ "backup.zip") do
    view |> element("#import-0") |> render_click()

    input =
      file_input(view, "#archive-form-0", :archive, [
        %{name: name, content: archive_bytes(members), type: "application/zip"}
      ])

    render_upload(input, name)
  end

  defp archive_bytes(members) do
    path = Path.join(System.tmp_dir!(), "mnemo-archive-#{System.unique_integer([:positive])}.zip")
    RenPyFixtures.write_archive(path, members)
    bytes = File.read!(path)
    File.rm!(path)
    bytes
  end
end
