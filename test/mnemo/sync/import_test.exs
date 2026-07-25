defmodule Mnemo.Sync.ImportTest do
  use Mnemo.DataCase, async: false

  alias Mnemo.Drive.Fake
  alias Mnemo.{Games, RenPy, RenPyFixtures, Sync}
  alias Mnemo.Sync.{Engine, Import, Restore}

  @confirmed [confirmed_closed: true, force: true]

  setup do
    Fake.reset()
    root = Path.join(System.tmp_dir!(), "mnemo-import-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, archives: Path.join(root, "archives")}
  end

  defp game_dir(root), do: Path.join(root, "MyGame-123")

  # A game with slot 1 on disk and one generation published, which is the
  # state someone is in when they go looking for an old backup.
  defp enrolled!(root) do
    dir = game_dir(root)
    RenPyFixtures.write_save(dir, "1-1-LT1.save", seed: "on-disk")
    File.write!(Path.join(dir, "persistent"), "on-disk")

    {:ok, game} = Games.enroll(%{save_directory: "MyGame-123", install_root: root})
    assert {:ok, %{generation: 1}} = Engine.run(game)

    {Games.get!(game.id), dir}
  end

  defp archive!(ctx, name, members) do
    RenPyFixtures.write_archive(Path.join(ctx.archives, name), members)
  end

  defp read(path), do: File.read!(path)

  describe "inspect_archive/2" do
    test "finds saves however deep they sit inside the archive", ctx do
      {game, _dir} = enrolled!(ctx.root)

      path =
        archive!(ctx, "takeout.zip", [
          {"Takeout/Drive/MyGame-123/1-1-LT1.save", [seed: "a"]},
          {"Takeout/Drive/MyGame-123/1-2-LT1.save", [seed: "b", save_name: "before the cave"]},
          {"Takeout/Drive/MyGame-123/persistent", {:raw, "p"}}
        ])

      assert {:ok, found} = Import.inspect_archive(path, game)
      assert Enum.map(found.entries, & &1.name) == ["1-1-LT1.save", "1-2-LT1.save", "persistent"]
      assert Enum.map(found.entries, & &1.slot) == [{:slot, 1, "1"}, {:slot, 1, "2"}, :persistent]
    end

    test "marks which saves the folder already has", ctx do
      {game, _dir} = enrolled!(ctx.root)

      path =
        archive!(ctx, "mixed.zip", [
          {"1-1-LT1.save", [seed: "a"]},
          {"1-9-LT1.save", [seed: "b"]}
        ])

      assert {:ok, found} = Import.inspect_archive(path, game)

      assert Enum.map(found.entries, &{&1.name, &1.present?}) == [
               {"1-1-LT1.save", true},
               {"1-9-LT1.save", false}
             ]
    end

    test "carries the screenshot and save name for the preview", ctx do
      {game, _dir} = enrolled!(ctx.root)
      path = archive!(ctx, "one.zip", [{"1-2-LT1.save", [save_name: "chapter two"]}])

      assert {:ok, %{entries: [entry]}} = Import.inspect_archive(path, game)
      assert entry.save_name == "chapter two"
      assert entry.screenshot == RenPyFixtures.png()
    end

    test "counts what it skipped instead of hiding it", ctx do
      {game, _dir} = enrolled!(ctx.root)

      path =
        archive!(ctx, "noisy.zip", [
          {"1-1-LT1.save", [seed: "a"]},
          # Resource forks and directory entries are archive noise, not
          # files the player would expect to see counted.
          {"__MACOSX/._1-1-LT1.save", {:raw, "resource fork"}},
          {"readme.txt", {:raw, "notes"}},
          {"_reload-1.save", [seed: "internal"]},
          {"nested/1-1-LT1.save", [seed: "same name, other folder"]}
        ])

      assert {:ok, found} = Import.inspect_archive(path, game)
      assert Enum.map(found.entries, & &1.name) == ["1-1-LT1.save"]
      assert found.ignored == 2
      assert found.duplicates == 1
    end

    test "reports a file that is not a zip at all", ctx do
      {game, _dir} = enrolled!(ctx.root)
      path = Path.join(ctx.archives, "not-a-zip.zip")
      File.mkdir_p!(ctx.archives)
      File.write!(path, :crypto.strong_rand_bytes(256))

      assert {:error, :unreadable_archive, _} = Import.inspect_archive(path, game)
    end
  end

  describe "importing" do
    test "adds the missing saves and leaves the existing ones alone", ctx do
      {game, dir} = enrolled!(ctx.root)
      before = read(Path.join(dir, "1-1-LT1.save"))

      path =
        archive!(ctx, "backup.zip", [
          {"1-1-LT1.save", [seed: "from-archive"]},
          {"1-2-LT1.save", [seed: "b"]},
          {"1-3-LT1.save", [seed: "c"]}
        ])

      assert {:ok, result} = Import.run(game, path, @confirmed)
      assert result.imported == 2
      assert result.skipped == 1

      assert read(Path.join(dir, "1-1-LT1.save")) == before
      assert File.regular?(Path.join(dir, "1-2-LT1.save"))
      assert File.regular?(Path.join(dir, "1-3-LT1.save"))
    end

    test "overwrite mode replaces the same names", ctx do
      {game, dir} = enrolled!(ctx.root)
      before = read(Path.join(dir, "1-1-LT1.save"))
      path = archive!(ctx, "backup.zip", [{"1-1-LT1.save", [seed: "from-archive"]}])

      assert {:ok, %{imported: 1, skipped: 0}} =
               Import.run(game, path, [mode: :overwrite] ++ @confirmed)

      assert read(Path.join(dir, "1-1-LT1.save")) != before
    end

    test "never removes a save the archive does not mention", ctx do
      {game, dir} = enrolled!(ctx.root)
      RenPyFixtures.write_save(dir, "2-4-LT1.save", seed: "only on disk")
      File.mkdir_p!(Path.join(dir, "sync"))
      File.write!(Path.join([dir, "sync", "leftover"]), "renpy-internal")

      path = archive!(ctx, "backup.zip", [{"1-2-LT1.save", [seed: "b"]}])

      assert {:ok, _} = Import.run(game, path, [mode: :overwrite] ++ @confirmed)

      assert File.regular?(Path.join(dir, "2-4-LT1.save"))
      assert read(Path.join([dir, "sync", "leftover"])) == "renpy-internal"
    end

    test "publishes the imported state so it reaches Drive", ctx do
      {game, _dir} = enrolled!(ctx.root)
      path = archive!(ctx, "backup.zip", [{"1-2-LT1.save", [seed: "b"]}])

      assert {:ok, %{generation: 2}} = Import.run(game, path, @confirmed)

      names =
        Sync.get_generation(game.id, 2).manifest
        |> Enum.map(& &1["rel_path"])

      assert "1-2-LT1.save" in names
      assert Games.get!(game.id).last_generation_seen == 2
    end

    test "the state before the import is recoverable as a generation", ctx do
      {game, dir} = enrolled!(ctx.root)
      # Work that was never synced is what a safety generation exists for.
      RenPyFixtures.write_save(dir, "1-5-LT1.save", seed: "never-synced")

      path = archive!(ctx, "backup.zip", [{"1-2-LT1.save", [seed: "b"]}])

      assert {:ok, %{safety: {:published, 2}}} = Import.run(game, path, @confirmed)

      assert {:ok, _} = Restore.run(Games.get!(game.id), 2, @confirmed)
      assert File.regular?(Path.join(dir, "1-5-LT1.save"))
      refute File.regular?(Path.join(dir, "1-2-LT1.save"))
    end

    test "the backup folder is dropped once the safety generation exists", ctx do
      {game, _dir} = enrolled!(ctx.root)
      path = archive!(ctx, "backup.zip", [{"1-2-LT1.save", [seed: "b"]}])

      assert {:ok, %{backup: nil}} = Import.run(game, path, @confirmed)
      assert Restore.list_backups(Games.get!(game.id)) == []
    end

    test "an import backup is not offered as a game to enroll", ctx do
      {game, _dir} = enrolled!(ctx.root)
      path = archive!(ctx, "backup.zip", [{"1-2-LT1.save", [seed: "b"]}])

      assert {:ok, %{backup: backup}} =
               Import.run(game, path, [safety_generation: false, publish: false] ++ @confirmed)

      assert File.dir?(backup)
      assert RenPy.scan([ctx.root]) |> Enum.map(& &1.save_directory) == ["MyGame-123"]
    end

    test "replace mode clears the saves the folder had", ctx do
      {game, dir} = enrolled!(ctx.root)
      RenPyFixtures.write_save(dir, "2-4-LT1.save", seed: "reference save")

      path =
        archive!(ctx, "backup.zip", [
          {"1-2-LT1.save", [seed: "b"]},
          {"1-3-LT1.save", [seed: "c"]}
        ])

      assert {:ok, %{imported: 2, removed: 3}} =
               Import.run(game, path, [mode: :replace] ++ @confirmed)

      # The folder now holds the archive and nothing else.
      assert File.ls!(dir) |> Enum.sort() == ["1-2-LT1.save", "1-3-LT1.save"]
    end

    test "what replace mode removed is recoverable from the safety generation", ctx do
      {game, dir} = enrolled!(ctx.root)
      path = archive!(ctx, "backup.zip", [{"1-2-LT1.save", [seed: "b"]}])

      assert {:ok, %{safety: :current}} = Import.run(game, path, [mode: :replace] ++ @confirmed)
      refute File.exists?(Path.join(dir, "1-1-LT1.save"))

      assert {:ok, _} = Restore.run(Games.get!(game.id), 1, @confirmed)
      assert File.regular?(Path.join(dir, "1-1-LT1.save"))
      assert read(Path.join(dir, "persistent")) == "on-disk"
    end

    test "replace mode never deletes what no generation holds", ctx do
      {game, dir} = enrolled!(ctx.root)
      # Autosaves are off for this game, so they are in no manifest —
      # deleting them would not be undoable, which is why they stay.
      RenPyFixtures.write_save(dir, "auto-1-LT1.save", seed: "autosave")
      File.mkdir_p!(Path.join(dir, "sync"))
      File.write!(Path.join([dir, "sync", "leftover"]), "renpy-internal")

      path = archive!(ctx, "backup.zip", [{"1-2-LT1.save", [seed: "b"]}])

      assert {:ok, _} = Import.run(game, path, [mode: :replace] ++ @confirmed)

      assert File.regular?(Path.join(dir, "auto-1-LT1.save"))
      assert read(Path.join([dir, "sync", "leftover"])) == "renpy-internal"
    end

    test "the plan names the files replace mode will delete", ctx do
      {game, _dir} = enrolled!(ctx.root)

      path =
        archive!(ctx, "backup.zip", [
          {"1-1-LT1.save", [seed: "a"]},
          {"1-2-LT1.save", [seed: "b"]}
        ])

      {:ok, found} = Import.inspect_archive(path, game)

      # A file the archive provides is overwritten, not deleted first.
      assert Import.plan(game, found, :replace).remove == ["persistent"]
      assert Import.plan(game, found, :add_missing).remove == []
      assert Import.plan(game, found, :overwrite).remove == []
    end

    test "persistent comes across even though it is not a zip", ctx do
      {game, dir} = enrolled!(ctx.root)
      path = archive!(ctx, "backup.zip", [{"persistent", {:raw, "from-archive"}}])

      assert {:ok, %{imported: 1}} = Import.run(game, path, [mode: :overwrite] ++ @confirmed)
      assert read(Path.join(dir, "persistent")) == "from-archive"
    end
  end

  describe "refusing to write" do
    test "a truncated save in the archive aborts the whole import", ctx do
      {game, dir} = enrolled!(ctx.root)
      whole = RenPyFixtures.save_bytes(seed: "good")
      half = binary_part(whole, 0, div(byte_size(whole), 2))

      path =
        archive!(ctx, "corrupt.zip", [
          {"1-2-LT1.save", [seed: "good"]},
          {"1-3-LT1.save", {:raw, half}}
        ])

      assert {:error, :invalid_save, detail} = Import.run(game, path, @confirmed)
      assert detail.file == "1-3-LT1.save"

      # Nothing partial lands: the good save from the same archive is not
      # in the folder either.
      refute File.exists?(Path.join(dir, "1-2-LT1.save"))
      refute File.exists?(Path.join(dir, "1-3-LT1.save"))
      assert Restore.list_backups(Games.get!(game.id)) == []
    end

    test "a zip that opens but holds no Ren'Py saves", ctx do
      {game, _dir} = enrolled!(ctx.root)
      path = archive!(ctx, "photos.zip", [{"holiday.jpg", {:raw, "jpeg"}}])

      assert {:error, :no_saves_in_archive, _} = Import.run(game, path, @confirmed)
    end

    test "an archive whose saves are all already in the folder", ctx do
      {game, _dir} = enrolled!(ctx.root)
      path = archive!(ctx, "same.zip", [{"1-1-LT1.save", [seed: "whatever"]}])

      assert {:error, :nothing_to_import, %{already_present: 1}} =
               Import.run(game, path, @confirmed)
    end

    test "without an explicit confirmation that the game is closed", ctx do
      {game, dir} = enrolled!(ctx.root)
      path = archive!(ctx, "backup.zip", [{"1-2-LT1.save", [seed: "b"]}])

      assert {:error, :confirmation_required, _} = Import.run(game, path, [])
      refute File.exists?(Path.join(dir, "1-2-LT1.save"))
    end

    test "while the folder is still being written to", ctx do
      {game, dir} = enrolled!(ctx.root)
      path = archive!(ctx, "backup.zip", [{"1-2-LT1.save", [seed: "b"]}])

      assert {:error, :game_may_be_running, _} =
               Import.run(game, path, confirmed_closed: true)

      refute File.exists?(Path.join(dir, "1-2-LT1.save"))
    end

    test "an archive entry that would fold onto a save already there", ctx do
      {game, dir} = enrolled!(ctx.root)
      on_exit(fn -> Application.delete_env(:mnemo, :case_insensitive_filesystem) end)
      Application.put_env(:mnemo, :case_insensitive_filesystem, true)

      # The folder has 1-1-LT1.save; on Windows this entry lands on top of
      # it, which `:add_missing` promised would never happen.
      path = archive!(ctx, "case.zip", [{"1-1-lt1.save", [seed: "other"]}])
      before = read(Path.join(dir, "1-1-LT1.save"))

      assert {:error, :case_collision, detail} = Import.run(game, path, @confirmed)
      assert detail.groups == [["1-1-LT1.save", "1-1-lt1.save"]]
      assert read(Path.join(dir, "1-1-LT1.save")) == before
      refute File.exists?(Path.join(dir, "1-1-lt1.save"))
    end

    test "two archive entries that differ only in case", ctx do
      {game, _dir} = enrolled!(ctx.root)
      on_exit(fn -> Application.delete_env(:mnemo, :case_insensitive_filesystem) end)
      Application.put_env(:mnemo, :case_insensitive_filesystem, true)

      path =
        archive!(ctx, "case.zip", [
          {"1-Save-LT1.save", [seed: "a"]},
          {"1-save-LT1.save", [seed: "b"]}
        ])

      assert {:error, :case_collision, _} = Import.run(game, path, @confirmed)
    end

    test "when the save folder is gone", ctx do
      {game, dir} = enrolled!(ctx.root)
      path = archive!(ctx, "backup.zip", [{"1-2-LT1.save", [seed: "b"]}])
      File.rm_rf!(dir)

      assert {:error, :missing_folder, _} = Import.run(game, path, @confirmed)
      # Rule 1: the folder the game did not create is not created here.
      refute File.exists?(dir)
    end
  end
end
