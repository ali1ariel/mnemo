defmodule Mnemo.Sync.ConflictTest do
  @moduledoc """
  Two machines against one remote, which is the only way these paths
  happen for real. Device B is simulated by swapping this machine's
  `device_id` and pointing a second install root at its own copy of the
  save folder — the same trick the spec asks for.
  """

  use Mnemo.DataCase, async: false

  alias Mnemo.Drive.Fake
  alias Mnemo.{Games, RenPyFixtures, Settings, Sync}
  alias Mnemo.Sync.{Conflict, Engine, Restore}

  @closed [confirmed_closed: true, force: true]

  setup do
    Fake.reset()
    base = Path.join(System.tmp_dir!(), "mnemo-conflict-#{System.unique_integer([:positive])}")
    root_a = Path.join(base, "device-a")
    root_b = Path.join(base, "device-b")
    File.mkdir_p!(Path.join(root_a, "MyGame-123"))
    File.mkdir_p!(Path.join(root_b, "MyGame-123"))
    on_exit(fn -> File.rm_rf!(base) end)

    {:ok,
     root_a: root_a,
     root_b: root_b,
     dir_a: Path.join(root_a, "MyGame-123"),
     dir_b: Path.join(root_b, "MyGame-123")}
  end

  defp enroll!(root) do
    {:ok, game} = Games.enroll(%{save_directory: "MyGame-123", install_root: root})
    game
  end

  # Each device has its own identity and its own row; only the remote is
  # shared, exactly as on two real machines.
  defp as_device(device_id, fun) do
    previous = Settings.device_id()
    Settings.put("device_id", device_id)

    try do
      fun.()
    after
      Settings.put("device_id", previous)
    end
  end

  defp diverged(%{dir_a: dir_a, dir_b: dir_b, root_a: root_a, root_b: root_b}) do
    # Device A syncs a first generation.
    RenPyFixtures.write_save(dir_a, "1-1-LT1.save", seed: "shared")
    File.write!(Path.join(dir_a, "persistent"), "shared")
    game_a = enroll!(root_a)
    {:ok, %{generation: 1}} = Engine.run(game_a)

    # Device B starts from the same files and catches up to generation 1.
    File.cp!(Path.join(dir_a, "1-1-LT1.save"), Path.join(dir_b, "1-1-LT1.save"))
    File.cp!(Path.join(dir_a, "persistent"), Path.join(dir_b, "persistent"))

    game_b =
      as_device("device-b", fn ->
        game_b = enroll!(root_b)
        {:ok, _} = Games.set_last_generation_seen(game_b, 1)

        # B plays on and publishes generation 2.
        RenPyFixtures.write_save(dir_b, "1-2-LT1.save", seed: "from-b")
        File.write!(Path.join(dir_b, "persistent"), "written-by-b")
        {:ok, %{generation: 2}} = Engine.run(Games.get!(game_b.id))
        Games.get!(game_b.id)
      end)

    # Meanwhile A played offline and has its own uncommitted work.
    RenPyFixtures.write_save(dir_a, "1-3-LT1.save", seed: "from-a")
    File.write!(Path.join(dir_a, "persistent"), "written-by-a")

    %{game_a: Games.get!(game_a.id), game_b: game_b}
  end

  test "a device that synced behind another one is told, and nothing is written", ctx do
    %{game_a: game_a} = diverged(ctx)

    assert {:error, :conflict, %{reason: :remote_ahead, remote_head: 2, last_seen: 1}} =
             Engine.run(game_a)

    assert File.read!(Path.join(ctx.dir_a, "persistent")) == "written-by-a"
  end

  describe "sides/1" do
    test "names what differs between the two machines", ctx do
      %{game_a: game_a} = diverged(ctx)

      assert {:ok, sides} = Conflict.sides(game_a)

      assert sides.local.generation == 1
      assert sides.remote.generation == 2
      assert sides.remote.device_id == "device-b"
      refute sides.forked?

      paths = Enum.map(sides.diverging, & &1.rel_path)
      assert "1-2-LT1.save" in paths
      assert "1-3-LT1.save" in paths
      assert "persistent" in paths
      # Untouched on both sides, so it must not be listed as at stake.
      refute "1-1-LT1.save" in paths

      assert Enum.find(sides.diverging, &(&1.rel_path == "1-2-LT1.save")).state == :only_remote
      assert Enum.find(sides.diverging, &(&1.rel_path == "1-3-LT1.save")).state == :only_local
      assert Enum.find(sides.diverging, &(&1.rel_path == "persistent")).state == :changed
    end
  end

  describe "keep_local" do
    test "publishes this machine's files on top and leaves them where they are", ctx do
      %{game_a: game_a} = diverged(ctx)

      assert {:ok, %{resolution: :keep_local, generation: 3}} =
               Conflict.resolve(game_a, :keep_local)

      # The files never moved.
      assert File.read!(Path.join(ctx.dir_a, "persistent")) == "written-by-a"
      assert File.exists?(Path.join(ctx.dir_a, "1-3-LT1.save"))

      # And the other device's work is still in history, not deleted.
      assert {:ok, manifest} = Fake.read_path(~w(mnemo games MyGame-123 generations 000002.json))
      assert Jason.decode!(manifest)["device_id"] == "device-b"

      # The conflict is over: syncing again is quiet.
      assert {:ok, :no_changes} = Engine.run(Games.get!(game_a.id))
    end

    test "identical content on both sides settles without a new generation", ctx do
      %{game_a: game_a} = diverged(ctx)

      # Make A match generation 2 exactly.
      File.cp!(Path.join(ctx.dir_b, "1-2-LT1.save"), Path.join(ctx.dir_a, "1-2-LT1.save"))
      File.rm!(Path.join(ctx.dir_a, "1-3-LT1.save"))
      File.write!(Path.join(ctx.dir_a, "persistent"), "written-by-b")

      assert {:ok, %{resolution: :keep_local, result: :no_changes}} =
               Conflict.resolve(game_a, :keep_local)

      assert Games.get!(game_a.id).last_generation_seen == 2
    end
  end

  describe "keep_remote" do
    test "brings the other machine's files down and saves the local ones first", ctx do
      %{game_a: game_a} = diverged(ctx)

      assert {:ok, %{resolution: :keep_remote, generation: 2} = result} =
               Conflict.resolve(game_a, :keep_remote, @closed)

      # Device B's files are now on disk.
      assert File.read!(Path.join(ctx.dir_a, "persistent")) == "written-by-b"
      assert File.exists?(Path.join(ctx.dir_a, "1-2-LT1.save"))
      refute File.exists?(Path.join(ctx.dir_a, "1-3-LT1.save"))

      # The local work was published before being overwritten, so it is
      # recoverable rather than gone.
      assert {:published, 3} = result.safety
      assert result.backup == nil

      assert {:ok, _} = Restore.run(Games.get!(game_a.id), 3, @closed)
      assert File.read!(Path.join(ctx.dir_a, "persistent")) == "written-by-a"
      assert File.exists?(Path.join(ctx.dir_a, "1-3-LT1.save"))
    end

    test "the divergence is settled: the next sync is ordinary, not another conflict", ctx do
      %{game_a: game_a} = diverged(ctx)

      assert {:ok, _} = Conflict.resolve(game_a, :keep_remote, @closed)

      # Generation 3 holds the work this device had before the swap, so
      # the files now on disk are new relative to the head and get a
      # generation of their own. Noisy is fine; conflicted would not be.
      assert {:ok, %{generation: 4}} = Engine.run(Games.get!(game_a.id))
      assert {:ok, :no_changes} = Engine.run(Games.get!(game_a.id))
    end

    test "refuses without a confirmation that the game is closed", ctx do
      %{game_a: game_a} = diverged(ctx)

      assert {:error, :confirmation_required, _} = Conflict.resolve(game_a, :keep_remote, [])
      assert File.read!(Path.join(ctx.dir_a, "persistent")) == "written-by-a"
      assert Games.get!(game_a.id).last_generation_seen == 1
    end
  end

  describe "a second machine enrolling a game that already has history" do
    test "sees a foreign lineage and can adopt it", ctx do
      %{dir_a: dir_a, dir_b: dir_b, root_a: root_a, root_b: root_b} = ctx

      RenPyFixtures.write_save(dir_a, "1-1-LT1.save", seed: "from-a")
      File.write!(Path.join(dir_a, "persistent"), "from-a")
      game_a = enroll!(root_a)
      {:ok, %{generation: 1}} = Engine.run(game_a)

      as_device("device-b", fn ->
        # B only has the reference save Ren'Py wrote on first launch.
        File.write!(Path.join(dir_b, "persistent"), "fresh-install")
        game_b = enroll!(root_b)

        assert {:error, :conflict, %{reason: :foreign_lineage, remote_head: 1}} =
                 Engine.run(game_b)

        assert {:ok, sides} = Conflict.sides(Games.get!(game_b.id))
        assert sides.local.generation == 0
        assert sides.remote.device_id != "device-b"

        assert {:ok, %{resolution: :keep_remote}} =
                 Conflict.resolve(Games.get!(game_b.id), :keep_remote, @closed)

        assert File.read!(Path.join(dir_b, "persistent")) == "from-a"
        assert File.exists?(Path.join(dir_b, "1-1-LT1.save"))

        # The fresh install's own file was not thrown away.
        assert {:ok, _} = Restore.run(Games.get!(game_b.id), 2, @closed)
        assert File.read!(Path.join(dir_b, "persistent")) == "fresh-install"
      end)
    end
  end

  describe "forks" do
    test "two devices on the same generation number are reported, not guessed at", ctx do
      %{game_a: game_a} = diverged(ctx)

      {:ok, _} =
        Fake.seed_file(
          ~w(mnemo games MyGame-123 generations 000002.json),
          Jason.encode!(%{"number" => 2, "device_id" => "device-c", "files" => []})
        )

      assert {:ok, sides} = Conflict.sides(Games.get!(game_a.id))
      assert sides.forked?

      assert {:error, :conflict, %{reason: :fork}} = Conflict.resolve(game_a, :keep_local)
      assert Sync.head_generation(game_a.id).number == 1
    end
  end
end
