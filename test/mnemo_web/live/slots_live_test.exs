defmodule MnemoWeb.SlotsLiveTest do
  use MnemoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mnemo.Drive.Fake
  alias Mnemo.{Games, RenPyFixtures}
  alias Mnemo.Sync.{Engine, Restore}

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

  describe "options" do
    test "toggling autosave backup persists and changes what gets synced", %{
      conn: conn,
      root: root
    } do
      game = enroll_with_saves!(root)
      refute game.sync_autosaves

      {:ok, view, _html} = live(conn, ~p"/games/#{game.id}")
      assert has_element?(view, "#game-options")

      view
      |> form("#options-form", %{"name" => "My Game", "sync_autosaves" => "true"})
      |> render_submit()

      game = Games.get!(game.id)
      assert game.sync_autosaves
      assert game.name == "My Game"

      tracked =
        Mnemo.RenPy.tracked_files(Path.join(root, "MyGame-123"),
          sync_autosaves: game.sync_autosaves
        )
        |> Enum.map(&elem(&1, 0))

      assert "auto-1-LT1.save" in tracked
      assert "quick-1-LT1.save" in tracked
    end

    test "unchecking turns autosave backup back off", %{conn: conn, root: root} do
      game = enroll_with_saves!(root)
      {:ok, _} = Games.update_game(game, %{sync_autosaves: true})

      {:ok, view, _html} = live(conn, ~p"/games/#{game.id}")

      # A browser sends nothing at all for an unchecked box, so the event
      # arrives without the key — which is what has to switch it off.
      render_submit(view, :save_options, %{"name" => "My Game"})

      refute Games.get!(game.id).sync_autosaves
    end
  end

  describe "conflict" do
    setup %{root: root} do
      dir = Path.join(root, "MyGame-123")
      RenPyFixtures.write_save(dir, "1-1-LT1.save", seed: "shared")
      File.write!(Path.join(dir, "persistent"), "local-work")

      {:ok, game} =
        Games.enroll(%{save_directory: "MyGame-123", install_root: root, name: "My Game"})

      assert {:ok, %{generation: 1}} = Engine.run(game)

      # Another device published on top of what this one last saw.
      {:ok, _} =
        Fake.seed_file(
          ~w(mnemo games MyGame-123 generations 000002.json),
          Jason.encode!(%{
            "number" => 2,
            "parent_number" => 1,
            "device_id" => "other-device",
            "files" => []
          })
        )

      File.write!(Path.join(dir, "persistent"), "newer-local-work")

      # The divergence has to be discovered through the server, the way it
      # is in the app: the page reflects live process state and must not
      # go poking at Drive on every mount.
      Mnemo.Game.subscribe()
      :ok = Mnemo.Game.sync_now(game.id)
      game_id = game.id
      assert_receive {:game, ^game_id, %{status: :conflict}}, 5_000

      {:ok, game: Games.get!(game.id), dir: dir}
    end

    test "shows both sides and what differs", %{conn: conn, game: game} do
      {:ok, view, html} = live(conn, ~p"/games/#{game.id}")

      assert has_element?(view, "#conflict")
      assert has_element?(view, "#conflict-local")
      assert has_element?(view, "#conflict-remote")
      assert has_element?(view, "#keep-local")
      assert has_element?(view, "#keep-remote")
      assert html =~ "other-device"
      assert html =~ "Two devices changed this game"
    end

    test "taking the other device's files requires confirming the game is closed",
         %{conn: conn, game: game} do
      {:ok, view, _html} = live(conn, ~p"/games/#{game.id}")
      assert has_element?(view, "#keep-remote-form input[name=confirmed][required]")
    end

    test "keeping this device's files publishes them and clears the conflict",
         %{conn: conn, game: game, dir: dir} do
      Mnemo.Game.subscribe()

      {:ok, view, _html} = live(conn, ~p"/games/#{game.id}")
      view |> element("#keep-local") |> render_click()

      game_id = game.id
      assert_receive {:game, ^game_id, %{status: :resolved}}, 5_000

      _ = :sys.get_state(view.pid)
      assert File.read!(Path.join(dir, "persistent")) == "newer-local-work"
      assert Games.get!(game.id).last_generation_seen == 3
      refute has_element?(view, "#conflict")
      assert render(view) =~ "Kept this device&#39;s files."
    end
  end

  describe "restore" do
    setup %{root: root} do
      dir = Path.join(root, "MyGame-123")
      RenPyFixtures.write_save(dir, "1-1-LT1.save", seed: "gen1")
      File.write!(Path.join(dir, "persistent"), "gen1")

      {:ok, game} =
        Games.enroll(%{save_directory: "MyGame-123", install_root: root, name: "My Game"})

      assert {:ok, %{generation: 1}} = Engine.run(game)

      RenPyFixtures.write_save(dir, "1-1-LT1.save", seed: "gen2")
      File.write!(Path.join(dir, "persistent"), "gen2")
      assert {:ok, %{generation: 2}} = Engine.run(Games.get!(game.id))

      {:ok, game: Games.get!(game.id), dir: dir}
    end

    test "history lists every generation with a restore button", %{conn: conn, game: game} do
      {:ok, view, html} = live(conn, ~p"/games/#{game.id}")

      assert has_element?(view, "#history")
      assert has_element?(view, "#generation-1")
      assert has_element?(view, "#generation-2")
      assert has_element?(view, "#restore-1")
      assert html =~ "Generation 2"
    end

    test "asking to restore requires confirming the game is closed", %{conn: conn, game: game} do
      {:ok, view, _html} = live(conn, ~p"/games/#{game.id}")

      view |> element("#restore-1") |> render_click()

      assert has_element?(view, "#restore-form-1")
      assert has_element?(view, "#restore-form-1 input[name=confirmed][required]")
      assert render(view) =~ "The game is closed"
    end

    test "confirming runs the restore and the files come back", %{
      conn: conn,
      game: game,
      dir: dir
    } do
      Mnemo.Game.subscribe()

      {:ok, view, _html} = live(conn, ~p"/games/#{game.id}")
      view |> element("#restore-1") |> render_click()

      view
      |> form("#restore-form-1", %{"confirmed" => "true"})
      |> render_submit()

      game_id = game.id
      assert_receive {:game, ^game_id, %{status: :restored}}, 5_000

      _ = :sys.get_state(view.pid)
      assert File.read!(Path.join(dir, "persistent")) == "gen1"
      assert render(view) =~ "Generation 1 is back in place."
    end

    test "cancelling closes the confirmation without touching anything", %{
      conn: conn,
      game: game,
      dir: dir
    } do
      {:ok, view, _html} = live(conn, ~p"/games/#{game.id}")

      view |> element("#restore-1") |> render_click()
      view |> element("#restore-form-1 button[phx-click=cancel_restore]") |> render_click()

      refute has_element?(view, "#restore-form-1")
      assert File.read!(Path.join(dir, "persistent")) == "gen2"
    end

    test "leftover backups can be rolled back from the page", %{
      conn: conn,
      game: game,
      dir: dir
    } do
      {:ok, %{backup: backup}} =
        Restore.run(game, 1, confirmed_closed: true, force: true, safety_generation: false)

      assert File.read!(Path.join(dir, "persistent")) == "gen1"

      {:ok, view, _html} = live(conn, ~p"/games/#{game.id}")
      assert has_element?(view, "#backups")

      view
      |> element("#backups button[phx-value-path='#{backup}']", "Roll back")
      |> render_click()

      assert File.read!(Path.join(dir, "persistent")) == "gen2"
      refute File.exists?(backup)

      # The rollback is itself undoable, so it leaves the state it replaced
      # as a fresh backup rather than clearing the section.
      assert has_element?(view, "#backups")
      assert [%{path: new_backup}] = Restore.list_backups(Games.get!(game.id))
      assert new_backup != backup
      assert File.read!(Path.join(new_backup, "persistent")) == "gen1"
    end
  end

  describe "importing an archive" do
    setup %{root: root} do
      dir = Path.join(root, "MyGame-123")
      RenPyFixtures.write_save(dir, "1-1-LT1.save", seed: "on-disk")
      File.write!(Path.join(dir, "persistent"), "p")

      {:ok, game} =
        Games.enroll(%{save_directory: "MyGame-123", install_root: root, name: "My Game"})

      assert {:ok, %{generation: 1}} = Engine.run(game)

      {:ok, game: Games.get!(game.id), dir: dir}
    end

    test "the upload area reads as somewhere to put a file", %{conn: conn, game: game} do
      {:ok, view, html} = live(conn, ~p"/games/#{game.id}")

      # A plain file input looks like a form field to fill in, so the
      # input is hidden behind a target that also accepts a dragged file.
      assert has_element?(view, "#archive-dropzone[phx-drop-target]")
      assert has_element?(view, "#archive-dropzone input[type=file].sr-only")
      assert html =~ "Drop a .zip here"
    end

    test "picking a zip previews it before anything is written", %{
      conn: conn,
      game: game,
      dir: dir
    } do
      {:ok, view, _html} = live(conn, ~p"/games/#{game.id}")

      html =
        upload_archive(view, [
          {"Takeout/MyGame-123/1-1-LT1.save", [seed: "x"]},
          {"Takeout/MyGame-123/1-2-LT1.save", [seed: "y", save_name: "before the cave"]}
        ])

      assert has_element?(view, "#import-preview")
      assert html =~ "backup.zip"
      assert html =~ "before the cave"
      assert has_element?(view, "#import-entry-1-1-LT1-save")
      assert has_element?(view, "#import-entry-1-2-LT1-save")

      # Only the save the folder does not have is counted.
      assert html =~ "1 save will be written."
      refute File.exists?(Path.join(dir, "1-2-LT1.save"))
    end

    test "confirming adds the missing save and leaves the existing one alone", %{
      conn: conn,
      game: game,
      dir: dir
    } do
      Mnemo.Game.subscribe()
      untouched = File.read!(Path.join(dir, "1-1-LT1.save"))

      {:ok, view, _html} = live(conn, ~p"/games/#{game.id}")

      upload_archive(view, [
        {"1-1-LT1.save", [seed: "from-archive"]},
        {"1-2-LT1.save", [seed: "y"]}
      ])

      view |> form("#import-form", %{"confirmed" => "true"}) |> render_submit()

      game_id = game.id
      assert_receive {:game, ^game_id, %{status: :imported}}, 5_000
      _ = :sys.get_state(view.pid)

      assert File.regular?(Path.join(dir, "1-2-LT1.save"))
      assert File.read!(Path.join(dir, "1-1-LT1.save")) == untouched
      assert render(view) =~ "1 save imported."
    end

    test "switching to replace mode changes what will be written", %{conn: conn, game: game} do
      {:ok, view, _html} = live(conn, ~p"/games/#{game.id}")

      upload_archive(view, [
        {"1-1-LT1.save", [seed: "x"]},
        {"1-2-LT1.save", [seed: "y"]}
      ])

      html =
        view
        |> element("#import-form input[phx-value-mode=overwrite]")
        |> render_click()

      assert html =~ "2 saves will be written."
    end

    test "the import needs a confirmation that the game is closed", %{conn: conn, game: game} do
      {:ok, view, _html} = live(conn, ~p"/games/#{game.id}")

      upload_archive(view, [{"1-2-LT1.save", [seed: "y"]}])

      assert has_element?(view, "#import-form input[name=confirmed][required]")
    end

    test "cancelling drops the upload without touching the folder", %{
      conn: conn,
      game: game,
      dir: dir
    } do
      {:ok, view, _html} = live(conn, ~p"/games/#{game.id}")

      upload_archive(view, [{"1-2-LT1.save", [seed: "y"]}])
      view |> element("#cancel-import") |> render_click()

      refute has_element?(view, "#import-preview")
      assert has_element?(view, "#archive-form")
      refute File.exists?(Path.join(dir, "1-2-LT1.save"))
    end

    test "a zip with no Ren'Py saves says so instead of offering to import", %{
      conn: conn,
      game: game
    } do
      {:ok, view, _html} = live(conn, ~p"/games/#{game.id}")

      html = upload_archive(view, [{"holiday.jpg", {:raw, "jpeg"}}])

      assert has_element?(view, "#import-nothing")
      refute has_element?(view, "#import-form")
      assert html =~ "No Ren&#39;Py saves in this archive."
    end

    test "a file that is not a zip is refused", %{conn: conn, game: game} do
      {:ok, view, _html} = live(conn, ~p"/games/#{game.id}")

      input =
        file_input(view, "#archive-form", :archive, [
          %{name: "backup.zip", content: :crypto.strong_rand_bytes(256), type: "application/zip"}
        ])

      html = render_upload(input, "backup.zip")

      refute has_element?(view, "#import-preview")
      assert html =~ "could not be opened as a zip archive"
    end
  end

  defp upload_archive(view, members, name \\ "backup.zip") do
    input =
      file_input(view, "#archive-form", :archive, [
        %{name: name, content: archive_bytes(members), type: "application/zip"}
      ])

    render_upload(input, name)
  end

  defp archive_bytes(members) do
    path =
      Path.join(System.tmp_dir!(), "mnemo-archive-#{System.unique_integer([:positive])}.zip")

    RenPyFixtures.write_archive(path, members)
    bytes = File.read!(path)
    File.rm!(path)
    bytes
  end
end
