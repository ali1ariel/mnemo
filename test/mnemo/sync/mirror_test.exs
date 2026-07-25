defmodule Mnemo.Sync.MirrorTest do
  use Mnemo.DataCase, async: false

  alias Mnemo.Drive.Fake
  alias Mnemo.{Games, RenPyFixtures}
  alias Mnemo.Sync.{Engine, Import, Mirror, Restore}

  @confirmed [confirmed_closed: true, force: true]

  setup do
    Fake.reset()
    root = Path.join(System.tmp_dir!(), "mnemo-mirror-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  # A packaged Ren'Py build: the user savedir plus the copy the engine
  # keeps beside the executable, holding the same bytes.
  defp installed!(ctx, saves) do
    dir = Path.join(ctx.root, "MyGame-123")
    install = Path.join([ctx.root, "steamapps", "common", "My Game"])
    mirror = Path.join([install, "game", "saves"])
    File.mkdir_p!(mirror)
    File.mkdir_p!(Path.join(install, "renpy"))

    for {name, opts} <- saves do
      RenPyFixtures.write_save(dir, name, opts)
      File.cp!(Path.join(dir, name), Path.join(mirror, name))
    end

    File.write!(Path.join(dir, "persistent"), "p")
    File.write!(Path.join(mirror, "persistent"), "p")

    {:ok, game} =
      Games.enroll(%{
        save_directory: "MyGame-123",
        install_root: ctx.root,
        install_path: install
      })

    {Games.get!(game.id), dir, mirror}
  end

  describe "plan/2" do
    test "finds the packaged copy of the saves", ctx do
      {game, dir, mirror} = installed!(ctx, [{"1-1-LT1.save", seed: "a"}])

      assert %{safe: [^mirror], diverged: []} = Mirror.plan(game, dir)
    end

    test "leaves a copy that drifted alone", ctx do
      {game, dir, mirror} = installed!(ctx, [{"1-1-LT1.save", seed: "a"}])
      # Bytes no generation ever captured: overwriting them would be an
      # overwrite with nothing to come back to.
      RenPyFixtures.write_save(mirror, "1-7-LT1.save", seed: "only in the mirror")

      assert %{safe: [], diverged: [^mirror]} = Mirror.plan(game, dir)
    end

    test "a game with no packaged copy has nothing to mirror", ctx do
      dir = Path.join(ctx.root, "Plain-1")
      RenPyFixtures.write_save(dir, "1-1-LT1.save")
      {:ok, game} = Games.enroll(%{save_directory: "Plain-1", install_root: ctx.root})

      assert Mirror.plan(game, dir) == %{safe: [], diverged: []}
    end
  end

  describe "restore" do
    test "a slot the restore removes does not survive in the packaged copy", ctx do
      {game, dir, mirror} = installed!(ctx, [{"1-1-LT1.save", seed: "a"}])
      assert {:ok, %{generation: 1}} = Engine.run(game)

      # A second slot, synced, then restored away.
      RenPyFixtures.write_save(dir, "1-2-LT1.save", seed: "b")
      File.cp!(Path.join(dir, "1-2-LT1.save"), Path.join(mirror, "1-2-LT1.save"))
      assert {:ok, %{generation: 2}} = Engine.run(Games.get!(game.id))

      assert {:ok, result} = Restore.run(Games.get!(game.id), 1, @confirmed)

      refute File.exists?(Path.join(dir, "1-2-LT1.save"))
      # Without this, Ren'Py reads the newest across locations and the
      # slot comes back the next time the game opens.
      refute File.exists?(Path.join(mirror, "1-2-LT1.save"))
      assert [%{path: ^mirror, removed: 1}] = result.mirrors.updated
    end

    test "restored bytes reach the packaged copy too", ctx do
      {game, dir, mirror} = installed!(ctx, [{"1-1-LT1.save", seed: "first"}])
      assert {:ok, %{generation: 1}} = Engine.run(game)

      RenPyFixtures.write_save(dir, "1-1-LT1.save", seed: "second")
      File.cp!(Path.join(dir, "1-1-LT1.save"), Path.join(mirror, "1-1-LT1.save"))
      assert {:ok, %{generation: 2}} = Engine.run(Games.get!(game.id))

      assert {:ok, _} = Restore.run(Games.get!(game.id), 1, @confirmed)

      assert File.read!(Path.join(mirror, "1-1-LT1.save")) ==
               File.read!(Path.join(dir, "1-1-LT1.save"))
    end

    test "a drifted copy is reported, not overwritten", ctx do
      {game, dir, mirror} = installed!(ctx, [{"1-1-LT1.save", seed: "a"}])
      assert {:ok, %{generation: 1}} = Engine.run(game)

      RenPyFixtures.write_save(dir, "1-2-LT1.save", seed: "b")
      assert {:ok, %{generation: 2}} = Engine.run(Games.get!(game.id))
      RenPyFixtures.write_save(mirror, "1-9-LT1.save", seed: "untracked work")

      assert {:ok, result} = Restore.run(Games.get!(game.id), 1, @confirmed)

      assert result.mirrors.diverged == [mirror]
      assert result.mirrors.updated == []
      assert File.regular?(Path.join(mirror, "1-9-LT1.save"))
    end
  end

  describe "import" do
    test "imported saves land in the packaged copy as well", ctx do
      {game, dir, mirror} = installed!(ctx, [{"1-1-LT1.save", seed: "a"}])
      assert {:ok, %{generation: 1}} = Engine.run(game)

      archive = Path.join(ctx.root, "backup.zip")
      RenPyFixtures.write_archive(archive, [{"1-2-LT1.save", [seed: "b"]}])

      assert {:ok, result} = Import.run(Games.get!(game.id), archive, @confirmed)

      assert File.regular?(Path.join(dir, "1-2-LT1.save"))
      assert File.regular?(Path.join(mirror, "1-2-LT1.save"))
      assert [%{path: ^mirror, copied: copied}] = result.mirrors.updated
      assert copied > 0
    end

    test "replace mode clears the packaged copy too", ctx do
      {game, dir, mirror} = installed!(ctx, [{"1-1-LT1.save", seed: "reference"}])
      assert {:ok, %{generation: 1}} = Engine.run(game)

      archive = Path.join(ctx.root, "backup.zip")
      RenPyFixtures.write_archive(archive, [{"1-5-LT1.save", [seed: "real"]}])

      assert {:ok, _} =
               Import.run(Games.get!(game.id), archive, [mode: :replace] ++ @confirmed)

      assert File.ls!(dir) |> Enum.sort() == ["1-5-LT1.save"]
      assert File.ls!(mirror) |> Enum.sort() == ["1-5-LT1.save"]
    end
  end

  test "a mirror location is never created, only written to when it exists", ctx do
    {game, dir, mirror} = installed!(ctx, [{"1-1-LT1.save", seed: "a"}])
    assert {:ok, %{generation: 1}} = Engine.run(game)

    File.rm_rf!(mirror)
    assert {:ok, result} = Restore.run(Games.get!(game.id), 1, @confirmed)

    assert result.mirrors.updated == []
    assert result.mirrors.diverged == []
    refute File.exists?(mirror)
    refute File.exists?(Path.join(dir, "..") |> Path.join("game"))
  end
end
