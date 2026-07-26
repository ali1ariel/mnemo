defmodule Mnemo.GamesTest do
  use Mnemo.DataCase, async: false

  alias Mnemo.{Games, Sync}

  setup do
    dir = Path.join(System.tmp_dir!(), "mnemo-games-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "enroll requires a save_directory" do
    assert {:error, changeset} = Games.enroll(%{install_root: "appdata"})
    assert %{save_directory: ["can't be blank"]} = errors_on(changeset)
  end

  test "the same save_directory cannot be enrolled twice under one root" do
    attrs = %{save_directory: "Game-1", install_root: "appdata", name: "Game"}
    assert {:ok, _game} = Games.enroll(attrs)
    assert {:error, changeset} = Games.enroll(attrs)
    assert %{save_directory: [_taken]} = errors_on(changeset)
  end

  test "the same save_directory under a different root is a distinct game" do
    assert {:ok, _} = Games.enroll(%{save_directory: "Game-1", install_root: "appdata"})
    assert {:ok, _} = Games.enroll(%{save_directory: "Game-1", install_root: "/portable/root"})
    assert length(Games.list()) == 2
  end

  describe "mirror_groups/1" do
    # One game, enrolled through both of the folders Ren'Py mirrors it to
    # — which is what a scan produced whenever neither folder held a
    # `.save` yet to match the other against.
    test "a game enrolled through both of its folders is one group", %{dir: dir} do
      install = Path.join(dir, "Some Game")
      local = Path.join([install, "game", "saves"])
      user = Path.join(dir, "SomeGame-1")
      File.mkdir_p!(local)
      File.mkdir_p!(user)
      File.write!(Path.join(local, "persistent"), "same game")
      File.write!(Path.join(user, "persistent"), "same game")

      {:ok, from_user} =
        Games.enroll(%{
          save_directory: "SomeGame-1",
          install_root: dir,
          install_path: install,
          name: "Some Game"
        })

      {:ok, from_install} =
        Games.enroll(%{
          save_directory: "saves",
          install_root: Path.join(install, "game"),
          install_path: install,
          name: "Some Game (install folder)"
        })

      assert [group] = Games.mirror_groups()
      assert Enum.sort(Enum.map(group, & &1.id)) == Enum.sort([from_user.id, from_install.id])
    end

    test "two different games are not a group", %{dir: dir} do
      a = Path.join(dir, "GameA-1")
      b = Path.join(dir, "GameB-2")
      File.mkdir_p!(a)
      File.mkdir_p!(b)
      File.write!(Path.join(a, "persistent"), "game a")
      File.write!(Path.join(b, "persistent"), "game b")

      {:ok, _} = Games.enroll(%{save_directory: "GameA-1", install_root: dir, name: "A"})
      {:ok, _} = Games.enroll(%{save_directory: "GameB-2", install_root: dir, name: "B"})

      assert Games.mirror_groups() == []
    end

    test "a single enrolled game is not a group", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "GameA-1"))
      {:ok, _} = Games.enroll(%{save_directory: "GameA-1", install_root: dir, name: "A"})

      assert Games.mirror_groups() == []
    end
  end

  describe "delete/1" do
    test "forgetting a game takes its generations with it and leaves the folder", %{dir: dir} do
      folder = Path.join(dir, "Game-1")
      File.mkdir_p!(folder)
      File.write!(Path.join(folder, "persistent"), "p")

      {:ok, game} = Games.enroll(%{save_directory: "Game-1", install_root: dir, name: "Game"})

      Sync.record_generation(game.id, %{
        number: 1,
        parent_number: 0,
        device_id: "device",
        validated: true,
        byte_size: 1,
        manifest: %{"files" => []}
      })

      assert {:ok, _} = Games.delete(game)

      assert Games.get(game.id) == nil
      assert Sync.list_generations(game.id) == []
      assert File.exists?(Path.join(folder, "persistent"))
    end
  end
end
