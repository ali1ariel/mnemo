defmodule Mnemo.Sync.RestoreTest do
  use Mnemo.DataCase, async: false

  alias Mnemo.Drive.Fake
  alias Mnemo.{Games, RenPy, RenPyFixtures, Sync}
  alias Mnemo.Sync.{Engine, Restore}

  @confirmed [confirmed_closed: true, force: true]

  setup do
    Fake.reset()
    root = Path.join(System.tmp_dir!(), "mnemo-restore-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp enroll!(root, save_directory \\ "MyGame-123", attrs \\ %{}) do
    {:ok, game} =
      Games.enroll(Map.merge(%{save_directory: save_directory, install_root: root}, attrs))

    game
  end

  defp game_dir(root), do: Path.join(root, "MyGame-123")

  defp read(path), do: File.read!(path)

  defp backups(game), do: Restore.list_backups(game)

  describe "restoring a previous generation" do
    setup %{root: root} do
      dir = game_dir(root)
      RenPyFixtures.write_save(dir, "1-1-LT1.save", seed: "gen1-a")
      File.write!(Path.join(dir, "persistent"), "persistent-gen1")

      game = enroll!(root)
      assert {:ok, %{generation: 1}} = Engine.run(game)

      # Second generation: slot 1 changes and a new slot appears.
      RenPyFixtures.write_save(dir, "1-1-LT1.save", seed: "gen2-a")
      RenPyFixtures.write_save(dir, "1-2-LT1.save", seed: "gen2-b")
      File.write!(Path.join(dir, "persistent"), "persistent-gen2")
      assert {:ok, %{generation: 2}} = Engine.run(Games.get!(game.id))

      {:ok, game: Games.get!(game.id), dir: dir}
    end

    test "puts back the old bytes and removes files added later", %{game: game, dir: dir} do
      gen1_slot1 = Sync.get_generation(game.id, 1).manifest |> hd()

      assert {:ok, result} = Restore.run(game, 1, @confirmed)
      assert result.generation == 1

      assert Base.encode16(:crypto.hash(:sha256, read(Path.join(dir, "1-1-LT1.save"))),
               case: :lower
             ) == gen1_slot1["sha256"]

      assert read(Path.join(dir, "persistent")) == "persistent-gen1"
      refute File.exists?(Path.join(dir, "1-2-LT1.save"))
    end

    test "publishes the pre-restore state first, so the restore is undoable",
         %{game: game, dir: dir} do
      assert {:ok, %{safety: safety}} = Restore.run(game, 1, @confirmed)

      # Nothing changed since generation 2, so generation 2 itself is the
      # state to come back to.
      assert safety == :current

      assert {:ok, %{generation: 3}} = Engine.run(Games.get!(game.id))
      assert {:ok, _} = Restore.run(Games.get!(game.id), 2, @confirmed)

      assert read(Path.join(dir, "persistent")) == "persistent-gen2"
      assert File.exists?(Path.join(dir, "1-2-LT1.save"))
    end

    test "uncommitted local work is captured as a generation before being overwritten",
         %{game: game, dir: dir} do
      RenPyFixtures.write_save(dir, "1-3-LT1.save", seed: "never-synced")

      assert {:ok, %{safety: {:published, 3}}} = Restore.run(game, 1, @confirmed)
      refute File.exists?(Path.join(dir, "1-3-LT1.save"))

      # The work that was about to be lost is recoverable from generation 3.
      assert {:ok, _} = Restore.run(Games.get!(game.id), 3, @confirmed)
      assert File.exists?(Path.join(dir, "1-3-LT1.save"))
    end

    test "the backup folder is cleaned up once a safety generation exists", %{game: game} do
      assert {:ok, %{backup: nil}} = Restore.run(game, 1, @confirmed)
      assert backups(game) == []
    end

    test "leaves last_generation_seen at the remote head, not the restored number",
         %{game: game} do
      assert {:ok, %{last_generation_seen: 2}} = Restore.run(game, 1, @confirmed)
      assert Games.get!(game.id).last_generation_seen == 2

      # A phantom conflict here would be the giveaway that the lineage was
      # rewound along with the files.
      assert {:ok, %{generation: 3}} = Engine.run(Games.get!(game.id))
    end

    test "files outside the synced set survive the swap", %{game: game, dir: dir} do
      # Autosaves are off by default, so they are not in any manifest.
      RenPyFixtures.write_save(dir, "auto-1-LT1.save", seed: "autosave")
      File.mkdir_p!(Path.join(dir, "sync"))
      File.write!(Path.join([dir, "sync", "leftover"]), "renpy-internal")

      assert {:ok, _} = Restore.run(game, 1, @confirmed)

      assert File.exists?(Path.join(dir, "auto-1-LT1.save"))
      assert read(Path.join([dir, "sync", "leftover"])) == "renpy-internal"
    end

    test "restore backups are not offered as games to enroll", %{root: root, game: game} do
      {:ok, _} = Restore.run(game, 1, [safety_generation: false] ++ @confirmed)

      assert [%{path: backup}] = backups(game)
      assert File.dir?(backup)
      assert RenPy.scan([root]) |> Enum.map(& &1.save_directory) == ["MyGame-123"]
    end
  end

  describe "refusing to run" do
    setup %{root: root} do
      dir = game_dir(root)
      RenPyFixtures.write_save(dir, "1-1-LT1.save", seed: "a")
      game = enroll!(root)
      assert {:ok, %{generation: 1}} = Engine.run(game)
      {:ok, game: Games.get!(game.id), dir: dir}
    end

    test "without an explicit confirmation that the game is closed", %{game: game, dir: dir} do
      before = read(Path.join(dir, "1-1-LT1.save"))

      assert {:error, :confirmation_required, _} = Restore.run(game, 1, [])
      assert read(Path.join(dir, "1-1-LT1.save")) == before
    end

    test "while the folder is still being written to", %{game: game} do
      assert {:error, :game_may_be_running, detail} =
               Restore.run(game, 1, confirmed_closed: true)

      assert detail.seconds_since_write < detail.quiet_seconds
    end

    test "when the save folder is gone", %{game: game, dir: dir} do
      File.rm_rf!(dir)
      assert {:error, :missing_folder, _} = Restore.run(game, 1, @confirmed)
    end

    test "when the generation does not exist anywhere", %{game: game} do
      assert {:error, :drive, %{op: :get_manifest}} = Restore.run(game, 99, @confirmed)
    end
  end

  # ext4 keeps these apart and NTFS does not, so a generation made here
  # can be one that cannot be written there.
  describe "restoring onto a filesystem that folds case" do
    setup %{root: root} do
      dir = game_dir(root)
      RenPyFixtures.write_save(dir, "1-Save-LT1.save", seed: "upper")
      RenPyFixtures.write_save(dir, "1-save-LT1.save", seed: "lower")
      File.write!(Path.join(dir, "persistent"), "p")

      game = enroll!(root)
      assert {:ok, %{generation: 1}} = Engine.run(game)

      on_exit(fn -> Application.delete_env(:mnemo, :case_insensitive_filesystem) end)
      {:ok, game: Games.get!(game.id), dir: dir}
    end

    test "refuses instead of silently dropping one of the two", %{game: game, dir: dir} do
      Application.put_env(:mnemo, :case_insensitive_filesystem, true)

      assert {:error, :case_collision, detail} = Restore.run(game, 1, @confirmed)
      assert detail.groups == [["1-Save-LT1.save", "1-save-LT1.save"]]

      # Refusing is only worth anything if it refuses before touching disk.
      assert read(Path.join(dir, "1-Save-LT1.save")) != read(Path.join(dir, "1-save-LT1.save"))
      assert backups(game) == []
    end

    test "the same generation restores fine where case is kept", %{game: game, dir: dir} do
      Application.put_env(:mnemo, :case_insensitive_filesystem, false)

      assert {:ok, _} = Restore.run(game, 1, @confirmed)
      assert File.regular?(Path.join(dir, "1-Save-LT1.save"))
      assert File.regular?(Path.join(dir, "1-save-LT1.save"))
    end
  end

  describe "corrupt or missing remote data" do
    setup %{root: root} do
      dir = game_dir(root)
      RenPyFixtures.write_save(dir, "1-1-LT1.save", seed: "a")
      File.write!(Path.join(dir, "persistent"), "p")
      game = enroll!(root)
      assert {:ok, %{generation: 1}} = Engine.run(game)
      {:ok, game: Games.get!(game.id), dir: dir}
    end

    test "a blob whose bytes do not match its hash never reaches the folder",
         %{game: game, dir: dir} do
      sha = Sync.get_generation(game.id, 1).manifest |> hd() |> Map.fetch!("sha256")
      before = read(Path.join(dir, "1-1-LT1.save"))

      {:ok, _} =
        Fake.overwrite_path(["mnemo", "games", "MyGame-123", "blobs", sha], "tampered-bytes")

      assert {:error, :download_failed, %{failures: [failure]}} =
               Restore.run(game, 1, @confirmed)

      assert failure.reason == :checksum_mismatch
      assert read(Path.join(dir, "1-1-LT1.save")) == before
      assert backups(game) == []
    end

    test "a missing blob aborts before anything is touched", %{game: game, dir: dir} do
      sha = Sync.get_generation(game.id, 1).manifest |> hd() |> Map.fetch!("sha256")
      before = read(Path.join(dir, "1-1-LT1.save"))

      :ok = Fake.delete_path(["mnemo", "games", "MyGame-123", "blobs", sha])

      assert {:error, :download_failed, %{failures: [%{reason: {:blob_missing, ^sha}}]}} =
               Restore.run(game, 1, @confirmed)

      assert read(Path.join(dir, "1-1-LT1.save")) == before
      assert File.exists?(Path.join(dir, "persistent"))
    end
  end

  describe "backups and rollback" do
    setup %{root: root} do
      dir = game_dir(root)
      RenPyFixtures.write_save(dir, "1-1-LT1.save", seed: "original")
      File.write!(Path.join(dir, "persistent"), "original")
      game = enroll!(root)
      assert {:ok, %{generation: 1}} = Engine.run(game)

      RenPyFixtures.write_save(dir, "1-1-LT1.save", seed: "newer")
      File.write!(Path.join(dir, "persistent"), "newer")
      assert {:ok, %{generation: 2}} = Engine.run(Games.get!(game.id))

      {:ok, game: Games.get!(game.id), dir: dir}
    end

    test "a restore that cannot publish a safety generation keeps its backup",
         %{game: game, dir: dir} do
      assert {:ok, %{backup: backup, safety: {:unavailable, :skipped}}} =
               Restore.run(game, 1, [safety_generation: false] ++ @confirmed)

      assert is_binary(backup)
      assert File.dir?(backup)
      assert read(Path.join(backup, "persistent")) == "newer"
      assert read(Path.join(dir, "persistent")) == "original"
    end

    test "rolling back puts the previous folder in place and keeps a new backup",
         %{game: game, dir: dir} do
      {:ok, %{backup: backup}} =
        Restore.run(game, 1, [safety_generation: false] ++ @confirmed)

      assert {:ok, %{backup: new_backup}} = Restore.rollback(game, backup)

      assert read(Path.join(dir, "persistent")) == "newer"
      assert read(Path.join(new_backup, "persistent")) == "original"
      refute File.exists?(backup)
    end

    test "discarding removes the folder", %{game: game} do
      {:ok, %{backup: backup}} =
        Restore.run(game, 1, [safety_generation: false] ++ @confirmed)

      assert :ok = Restore.discard(game, backup)
      refute File.exists?(backup)
      assert backups(game) == []
    end

    test "a path that is not one of this game's backups is refused", %{game: game, root: root} do
      outsider = Path.join(root, "not-a-backup")
      File.mkdir_p!(outsider)

      assert {:error, :unknown_backup, _} = Restore.rollback(game, outsider)
      assert {:error, :unknown_backup, _} = Restore.discard(game, outsider)
      assert {:error, :unknown_backup, _} = Restore.rollback(game, "/etc")
      assert File.dir?(outsider)
    end

    test "list_backups reports leftovers newest first", %{game: game} do
      {:ok, %{backup: first}} =
        Restore.run(game, 1, [safety_generation: false] ++ @confirmed)

      {:ok, %{backup: second}} =
        Restore.run(Games.get!(game.id), 2, [safety_generation: false] ++ @confirmed)

      names = backups(game) |> Enum.map(& &1.name)
      assert length(names) == 2
      assert names == Enum.sort(names, :desc)
      assert Path.basename(first) in names
      assert Path.basename(second) in names
    end
  end
end
