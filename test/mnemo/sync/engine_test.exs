defmodule Mnemo.Sync.EngineTest do
  use Mnemo.DataCase, async: false

  alias Mnemo.Drive.Fake
  alias Mnemo.{Games, RenPyFixtures, Settings, Sync}
  alias Mnemo.Sync.Engine

  setup do
    Fake.reset()
    root = Path.join(System.tmp_dir!(), "mnemo-engine-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp game_dir!(root, save_directory) do
    dir = Path.join(root, save_directory)
    File.mkdir_p!(dir)
    dir
  end

  defp enroll!(root, save_directory, attrs \\ %{}) do
    {:ok, game} =
      Games.enroll(Map.merge(%{save_directory: save_directory, install_root: root}, attrs))

    game
  end

  test "first sync publishes generation 1, dedupes into blobs and registers the device",
       %{root: root} do
    dir = game_dir!(root, "MyGame-123")
    RenPyFixtures.write_save(dir, "1-1-LT1.save", seed: "a")
    RenPyFixtures.write_save(dir, "2-Save Slot 3-LT1.save", seed: "b")
    File.write!(Path.join(dir, "persistent"), "persistent-bytes")
    RenPyFixtures.write_save(Path.join(dir, "sync"), "1-1-LT1.save", seed: "a")

    game = enroll!(root, "MyGame-123")

    assert {:ok, %{generation: 1, uploaded: 3, skipped: 0}} = Engine.run(game)

    game = Games.get!(game.id)
    assert game.last_generation_seen == 1
    assert game.remote_folder_id

    generation = Sync.head_generation(game.id)
    assert generation.number == 1
    assert generation.parent_number == 0
    assert generation.validated
    assert generation.device_id == Settings.device_id()
    assert generation.byte_size > 0
    assert length(generation.manifest) == 3

    {:ok, raw} = Fake.read_path(["mnemo", "games", game.id, "generations", "000001.json"])
    manifest = Jason.decode!(raw)
    assert manifest["number"] == 1
    assert manifest["parent_number"] == 0
    assert manifest["device_id"] == Settings.device_id()

    assert Enum.map(manifest["files"], & &1["rel_path"]) ==
             ["1-1-LT1.save", "2-Save Slot 3-LT1.save", "persistent"]

    assert Enum.map(manifest["files"], & &1["slot"]) == [
             %{"type" => "slot", "page" => 1, "name" => "1"},
             %{"type" => "slot", "page" => 2, "name" => "Save Slot 3"},
             %{"type" => "persistent"}
           ]

    {:ok, blobs} = Fake.list_path(["mnemo", "games", game.id, "blobs"])
    assert length(blobs) == 3

    for file <- manifest["files"] do
      assert Enum.any?(blobs, &(&1.name == file["sha256"]))
      assert Sync.get_blob(file["sha256"])
    end

    {:ok, devices_raw} = Fake.read_path(["mnemo", "devices.json"])
    assert %{"devices" => [%{"id" => device_id}]} = Jason.decode!(devices_raw)
    assert device_id == Settings.device_id()
  end

  test "sync with nothing changed writes no new generation", %{root: root} do
    dir = game_dir!(root, "MyGame-123")
    RenPyFixtures.write_save(dir, "1-1-LT1.save", seed: "a")
    game = enroll!(root, "MyGame-123")

    assert {:ok, %{generation: 1}} = Engine.run(game)
    uploads_after_first = Fake.upload_count()

    assert {:ok, :no_changes} = Engine.run(Games.get!(game.id))

    assert Fake.upload_count() == uploads_after_first
    {:ok, manifests} = Fake.list_path(["mnemo", "games", game.id, "generations"])
    assert length(manifests) == 1
    assert Games.get!(game.id).last_generation_seen == 1
  end

  test "changed and added files upload only the new blobs", %{root: root} do
    dir = game_dir!(root, "MyGame-123")
    RenPyFixtures.write_save(dir, "1-1-LT1.save", seed: "a")
    RenPyFixtures.write_save(dir, "1-2-LT1.save", seed: "b")
    File.write!(Path.join(dir, "persistent"), "persistent-bytes")

    game = enroll!(root, "MyGame-123")
    assert {:ok, %{generation: 1, uploaded: 3}} = Engine.run(game)

    RenPyFixtures.write_save(dir, "1-2-LT1.save", seed: "b-changed")
    RenPyFixtures.write_save(dir, "1-3-LT1.save", seed: "c")

    assert {:ok, %{generation: 2, uploaded: 2, skipped: 2}} = Engine.run(Games.get!(game.id))

    {:ok, raw} = Fake.read_path(["mnemo", "games", game.id, "generations", "000002.json"])
    manifest = Jason.decode!(raw)
    assert manifest["parent_number"] == 1
    assert length(manifest["files"]) == 4

    {:ok, blobs} = Fake.list_path(["mnemo", "games", game.id, "blobs"])
    assert length(blobs) == 5
  end

  test "remote head ahead of local is a conflict and nothing is written", %{root: root} do
    dir = game_dir!(root, "MyGame-123")
    RenPyFixtures.write_save(dir, "1-1-LT1.save", seed: "a")
    game = enroll!(root, "MyGame-123")
    assert {:ok, %{generation: 1}} = Engine.run(game)

    other_manifest =
      Jason.encode!(%{
        "number" => 2,
        "parent_number" => 1,
        "device_id" => "other-device",
        "files" => []
      })

    {:ok, _} =
      Fake.seed_file(["mnemo", "games", game.id, "generations", "000002.json"], other_manifest)

    RenPyFixtures.write_save(dir, "1-1-LT1.save", seed: "a-changed")

    assert {:error, :conflict, %{reason: :remote_ahead, remote_head: 2, last_seen: 1}} =
             Engine.run(Games.get!(game.id))

    {:ok, manifests} = Fake.list_path(["mnemo", "games", game.id, "generations"])
    assert length(manifests) == 2
    assert Games.get!(game.id).last_generation_seen == 1
  end

  test "duplicate generation numbers are detected as a fork", %{root: root} do
    dir = game_dir!(root, "MyGame-123")
    RenPyFixtures.write_save(dir, "1-1-LT1.save", seed: "a")
    game = enroll!(root, "MyGame-123")
    assert {:ok, %{generation: 1}} = Engine.run(game)

    duplicate = Jason.encode!(%{"number" => 1, "device_id" => "other-device", "files" => []})

    {:ok, _} =
      Fake.seed_file(["mnemo", "games", game.id, "generations", "000001.json"], duplicate)

    assert {:error, :conflict, %{reason: :fork, numbers: [1]}} = Engine.run(Games.get!(game.id))
  end

  test "enrolling over an existing remote lineage adopts the folder and conflicts",
       %{root: root} do
    dir = game_dir!(root, "MyGame-123")
    RenPyFixtures.write_save(dir, "1-1-LT1.save", seed: "local")

    other_uuid = Ecto.UUID.generate()

    {:ok, _} =
      Fake.seed_file(
        ["mnemo", "games", other_uuid, "game.json"],
        Jason.encode!(%{"id" => other_uuid, "save_directory" => "MyGame-123"})
      )

    {:ok, _} =
      Fake.seed_file(
        ["mnemo", "games", other_uuid, "generations", "000001.json"],
        Jason.encode!(%{"number" => 1, "device_id" => "other-device", "files" => []})
      )

    game = enroll!(root, "MyGame-123")

    assert {:error, :conflict, %{reason: :foreign_lineage, remote_head: 1}} = Engine.run(game)

    game = Games.get!(game.id)
    assert game.remote_folder_id != nil
    assert game.last_generation_seen == 0
  end

  test "a truncated save aborts the cycle before anything touches the remote", %{root: root} do
    dir = game_dir!(root, "MyGame-123")
    RenPyFixtures.write_save(dir, "1-1-LT1.save", seed: "a")
    RenPyFixtures.write_truncated_save(dir, "1-2-LT1.save", seed: "b")

    game = enroll!(root, "MyGame-123")

    assert {:error, :invalid_save, %{file: "1-2-LT1.save"}} = Engine.run(game)

    assert Fake.list_path(["mnemo"]) == {:error, :not_found}
    assert Sync.head_generation(game.id) == nil
    assert Games.get!(game.id).last_generation_seen == 0
  end

  test "autosaves and quicksaves sync only when enabled", %{root: root} do
    dir = game_dir!(root, "MyGame-123")
    RenPyFixtures.write_save(dir, "1-1-LT1.save", seed: "a")
    RenPyFixtures.write_save(dir, "auto-1-LT1.save", seed: "auto")
    RenPyFixtures.write_save(dir, "quick-1-LT1.save", seed: "quick")

    game = enroll!(root, "MyGame-123")
    assert {:ok, %{generation: 1}} = Engine.run(game)

    {:ok, raw} = Fake.read_path(["mnemo", "games", game.id, "generations", "000001.json"])
    assert Enum.map(Jason.decode!(raw)["files"], & &1["rel_path"]) == ["1-1-LT1.save"]

    {:ok, game} = Games.update_game(Games.get!(game.id), %{sync_autosaves: true})
    assert {:ok, %{generation: 2, uploaded: 2}} = Engine.run(game)

    {:ok, raw} = Fake.read_path(["mnemo", "games", game.id, "generations", "000002.json"])

    assert Enum.map(Jason.decode!(raw)["files"], & &1["rel_path"]) ==
             ["1-1-LT1.save", "auto-1-LT1.save", "quick-1-LT1.save"]
  end

  test "no-change detection survives a local database wipe", %{root: root} do
    dir = game_dir!(root, "MyGame-123")
    RenPyFixtures.write_save(dir, "1-1-LT1.save", seed: "a")
    game = enroll!(root, "MyGame-123")
    assert {:ok, %{generation: 1}} = Engine.run(game)

    Repo.delete_all(Mnemo.Sync.Generation)
    Repo.delete_all(Mnemo.Sync.Blob)
    uploads_before = Fake.upload_count()

    assert {:ok, :no_changes} = Engine.run(Games.get!(game.id))
    assert Fake.upload_count() == uploads_before
  end

  test "a save folder that vanished is a structured error", %{root: root} do
    game = enroll!(root, "Gone-1")
    assert {:error, :missing_folder, %{path: path}} = Engine.run(game)
    assert String.ends_with?(path, "Gone-1")
  end

  test "an empty save folder is a structured error", %{root: root} do
    game_dir!(root, "Fresh-1")
    game = enroll!(root, "Fresh-1")
    assert {:error, :no_saves, %{path: _path}} = Engine.run(game)
  end
end
