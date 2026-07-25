defmodule Mnemo.ResetTest do
  use Mnemo.DataCase, async: false

  alias Mnemo.Drive.Fake
  alias Mnemo.{Games, RenPyFixtures, Reset, Settings, Sync}
  alias Mnemo.Sync.Engine

  setup do
    Fake.reset()
    root = Path.join(System.tmp_dir!(), "mnemo-reset-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp synced_game!(root) do
    dir = Path.join(root, "MyGame-123")
    RenPyFixtures.write_save(dir, "1-1-LT1.save")
    {:ok, game} = Games.enroll(%{save_directory: "MyGame-123", install_root: root})
    {:ok, %{generation: 1}} = Engine.run(game)
    Games.get!(game.id)
  end

  test "local wipe clears game state but keeps credentials and device", %{root: root} do
    game = synced_game!(root)
    Settings.put_google_client_id("keep-id")
    Settings.put_google_client_secret("keep-secret")
    Settings.put_locale("pt_BR")
    device_id = Settings.device_id()

    counts = Reset.local()

    assert counts.games == 1
    assert counts.generations == 1
    assert counts.blobs >= 1
    assert Games.list() == []
    assert Sync.head_generation(game.id) == nil

    assert Settings.google_client_id() == "keep-id"
    assert Settings.google_client_secret() == "keep-secret"
    assert Settings.locale() == "pt_BR"
    assert Settings.device_id() == device_id
  end

  test "new_device forgets this machine's identity", %{root: root} do
    synced_game!(root)
    device_id = Settings.device_id()

    Reset.local(new_device: true)

    assert Settings.device_id() != device_id
  end

  test "local wipe leaves the remote untouched", %{root: root} do
    game = synced_game!(root)

    Reset.local()

    assert {:ok, _} =
             Fake.read_path(["mnemo", "games", "MyGame-123", "generations", "000001.json"])

    assert {:ok, _} = Fake.read_path(["mnemo", "games", "MyGame-123", "game.json"])
    refute game.id == nil
  end

  test "remote wipe deletes the whole mnemo folder", %{root: root} do
    synced_game!(root)
    assert {:ok, _} = Fake.list_path(["mnemo"])

    assert Reset.remote() == {:ok, :deleted}

    assert Fake.list_path(["mnemo"]) == {:error, :not_found}
  end

  test "remote wipe on a drive that never had mnemo is not an error" do
    assert Reset.remote() == {:ok, :absent}
  end

  test "all wipes both sides", %{root: root} do
    synced_game!(root)

    assert {:ok, %{remote: :deleted, local: counts}} = Reset.all()

    assert counts.games == 1
    assert Games.list() == []
    assert Fake.list_path(["mnemo"]) == {:error, :not_found}
  end

  test "a wiped local database resyncs into a fresh lineage", %{root: root} do
    synced_game!(root)
    Reset.all()

    dir = Path.join(root, "MyGame-123")
    {:ok, game} = Games.enroll(%{save_directory: "MyGame-123", install_root: root})

    assert {:ok, %{generation: 1}} = Engine.run(game)
  end
end
