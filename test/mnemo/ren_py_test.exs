defmodule Mnemo.RenPyTest do
  use ExUnit.Case, async: true

  alias Mnemo.RenPy
  alias Mnemo.RenPyFixtures

  setup do
    dir = Path.join(System.tmp_dir!(), "mnemo-renpy-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "parse_slot/1" do
    test "numeric slots with and without the LT suffix" do
      assert RenPy.parse_slot("1-1-LT1.save") == {:slot, 1, "1"}
      assert RenPy.parse_slot("2-4.save") == {:slot, 2, "4"}
      assert RenPy.parse_slot("10-12-LT1.save") == {:slot, 10, "12"}
    end

    test "free-form slot names as written by real games" do
      assert RenPy.parse_slot("1-Save Slot 9-LT1.save") == {:slot, 1, "Save Slot 9"}
      assert RenPy.parse_slot("3-my checkpoint.save") == {:slot, 3, "my checkpoint"}
    end

    test "autosaves and quicksaves" do
      assert RenPy.parse_slot("auto-3-LT1.save") == {:auto, 3}
      assert RenPy.parse_slot("auto-12.save") == {:auto, 12}
      assert RenPy.parse_slot("quick-1-LT1.save") == {:quick, 1}
      assert RenPy.parse_slot("quick-2.save") == {:quick, 2}
    end

    test "persistent" do
      assert RenPy.parse_slot("persistent") == :persistent
    end

    test "Ren'Py internals and junk classify as other" do
      assert RenPy.parse_slot("_reload-1-LT1.save") == :other
      assert RenPy.parse_slot("notes.txt") == :other
      assert RenPy.parse_slot("1-.save") == :other
      assert RenPy.parse_slot("nopage.save") == :other
      assert RenPy.parse_slot("persistent.new") == :other
    end
  end

  describe "suggest_name/1" do
    test "strips numeric suffix and splits camel case" do
      assert RenPy.suggest_name("CampBuddyScoutmastersSeason-1608150621") ==
               "Camp Buddy Scoutmasters Season"
    end

    test "handles underscores and plain names" do
      assert RenPy.suggest_name("my_little_game") == "my little game"
      assert RenPy.suggest_name("game") == "game"
    end
  end

  describe "validate_save/1" do
    test "accepts a well-formed save", %{dir: dir} do
      path = RenPyFixtures.write_save(dir, "1-1-LT1.save")
      assert RenPy.validate_save(path) == :ok
    end

    test "rejects a truncated save", %{dir: dir} do
      path = RenPyFixtures.write_truncated_save(dir, "1-1-LT1.save")
      assert {:error, %{file: "1-1-LT1.save"}} = RenPy.validate_save(path)
    end

    test "rejects a file that is not a zip", %{dir: dir} do
      path = RenPyFixtures.write_garbage_save(dir, "1-1-LT1.save")
      assert {:error, %{file: "1-1-LT1.save"}} = RenPy.validate_save(path)
    end

    test "rejects a zip missing the required members", %{dir: dir} do
      path = RenPyFixtures.write_save_missing_members(dir, "1-1-LT1.save")
      assert {:error, %{missing: missing}} = RenPy.validate_save(path)
      assert "log" in missing
      assert "json" in missing
    end
  end

  describe "extract_screenshot/1 and save_metadata/1" do
    test "extracts the embedded screenshot", %{dir: dir} do
      path = RenPyFixtures.write_save(dir, "1-1-LT1.save")
      assert {:ok, png} = RenPy.extract_screenshot(path)
      assert png == RenPyFixtures.png()
    end

    test "errors on a corrupt file", %{dir: dir} do
      path = RenPyFixtures.write_garbage_save(dir, "1-1-LT1.save")
      assert {:error, _reason} = RenPy.extract_screenshot(path)
    end

    test "reads the json metadata member", %{dir: dir} do
      path = RenPyFixtures.write_save(dir, "1-1-LT1.save", save_name: "Chapter 3")
      assert {:ok, %{"_save_name" => "Chapter 3"}} = RenPy.save_metadata(path)
    end
  end

  describe "scan/1" do
    test "lists only folders that look like games", %{dir: root} do
      RenPyFixtures.write_save(Path.join(root, "GameA-1"), "1-1-LT1.save")
      File.mkdir_p!(Path.join(root, "GameB-2"))
      File.write!(Path.join([root, "GameB-2", "persistent"]), "p")

      # Ren'Py's own token folder holds no saves and must not be listed.
      File.mkdir_p!(Path.join(root, "tokens"))
      File.write!(Path.join([root, "tokens", "security_keys.txt"]), "k")

      File.mkdir_p!(Path.join(root, "Empty"))
      File.write!(Path.join(root, "loose-file"), "x")

      entries = RenPy.scan([root])

      assert Enum.map(entries, & &1.save_directory) == ["GameA-1", "GameB-2"]

      game_a = Enum.find(entries, &(&1.save_directory == "GameA-1"))
      assert game_a.save_count == 1
      assert game_a.preview == RenPyFixtures.png()
      assert %DateTime{} = game_a.latest_save_at

      game_b = Enum.find(entries, &(&1.save_directory == "GameB-2"))
      assert game_b.save_count == 0
      assert game_b.preview == nil
    end

    test "a missing root scans to nothing" do
      assert RenPy.scan(["/nonexistent/renpy/root"]) == []
    end
  end

  describe "portable_installs/1" do
    # Ren'Py builds a MultiLocation out of the user savedir *and*
    # <gamedir>/saves, so a Steam or itch.io copy has a second live save
    # folder that scanning ~/.renpy alone never sees.
    defp write_install!(base, name, opts \\ []) do
      install = Path.join(base, name)
      File.mkdir_p!(Path.join(install, "renpy"))
      File.mkdir_p!(Path.join(install, "game"))

      if Keyword.get(opts, :saves, true) do
        File.mkdir_p!(Path.join([install, "game", "saves"]))
      end

      install
    end

    test "finds game-local save folders", %{dir: dir} do
      install = write_install!(dir, "Some Game")
      RenPyFixtures.write_save(Path.join([install, "game", "saves"]), "1-1-LT1.save")

      assert [%{name: "Some Game", path: path, install: ^install}] =
               RenPy.portable_installs([dir])

      assert path == Path.join([install, "game", "saves"])
    end

    test "ignores directories that are not Ren'Py builds", %{dir: dir} do
      File.mkdir_p!(Path.join([dir, "Not A Game", "game", "saves"]))
      write_install!(dir, "No Saves Yet", saves: false)

      assert RenPy.portable_installs([dir]) == []
    end

    test "the same install reached through a symlink is reported once", %{dir: dir} do
      real = Path.join(dir, "real")
      File.mkdir_p!(real)
      write_install!(real, "Some Game")

      link = Path.join(dir, "link")
      :ok = File.ln_s(real, link)

      assert [_one] = RenPy.portable_installs([real, link])
    end

    test "a missing search directory is not an error" do
      assert RenPy.portable_installs(["/nonexistent/steam/common"]) == []
    end
  end

  describe "group_mirrors/1" do
    defp entry(path, kind, name) do
      %{
        path: path,
        kind: kind,
        name: name,
        save_directory: Path.basename(path),
        root: Path.dirname(path)
      }
    end

    test "folders holding the same saves collapse into one game", %{dir: dir} do
      user = Path.join(dir, "user")
      steam = Path.join(dir, "steam")
      RenPyFixtures.write_save(user, "1-1-LT1.save", seed: "same")
      RenPyFixtures.write_save(steam, "1-1-LT1.save", seed: "same")

      assert [merged] =
               RenPy.group_mirrors([
                 entry(user, :user, "Game"),
                 entry(steam, :portable, "Game (Steam)")
               ])

      # The user savedir wins: it survives uninstalling the game.
      assert merged.path == user
      assert merged.mirrors == [steam]
    end

    test "different games stay separate", %{dir: dir} do
      a = Path.join(dir, "game-a")
      b = Path.join(dir, "game-b")
      RenPyFixtures.write_save(a, "1-1-LT1.save", seed: "a")
      RenPyFixtures.write_save(b, "1-1-LT1.save", seed: "bbbbbbbbbbbbbbbbbbbb")

      assert [one, two] =
               RenPy.group_mirrors([entry(a, :user, "A"), entry(b, :user, "B")])

      assert one.mirrors == []
      assert two.mirrors == []
    end

    test "a portable-only game keeps its own entry", %{dir: dir} do
      steam = Path.join(dir, "steam")
      RenPyFixtures.write_save(steam, "1-1-LT1.save", seed: "only")

      assert [merged] = RenPy.group_mirrors([entry(steam, :portable, "Game")])
      assert merged.path == steam
      assert merged.mirrors == []
    end
  end

  describe "list_saves/1" do
    setup %{dir: dir} do
      game = Path.join(dir, "Game-1")
      RenPyFixtures.write_save(game, "1-Save Slot 2-LT1.save", save_name: "Before the boss")
      RenPyFixtures.write_save(game, "auto-1-LT1.save")
      RenPyFixtures.write_garbage_save(game, "2-1-LT1.save")
      RenPyFixtures.write_save(game, "_reload-1-LT1.save")
      File.write!(Path.join(game, "persistent"), "p")
      RenPyFixtures.write_save(Path.join(game, "sync"), "1-1-LT1.save")
      {:ok, game: game}
    end

    test "lists slot files with metadata, skipping persistent and internals", %{game: game} do
      saves = RenPy.list_saves(game)

      assert Enum.map(saves, & &1.file) ==
               ["1-Save Slot 2-LT1.save", "2-1-LT1.save", "auto-1-LT1.save"]

      named = Enum.find(saves, &(&1.file == "1-Save Slot 2-LT1.save"))
      assert named.slot == {:slot, 1, "Save Slot 2"}
      assert named.save_name == "Before the boss"
      assert named.screenshot?
      assert named.size > 0
      assert %DateTime{} = named.mtime

      auto = Enum.find(saves, &(&1.file == "auto-1-LT1.save"))
      assert auto.slot == {:auto, 1}
      assert auto.save_name == nil
    end

    test "a corrupt save is still listed, without screenshot or name", %{game: game} do
      garbage = Enum.find(RenPy.list_saves(game), &(&1.file == "2-1-LT1.save"))
      refute garbage.screenshot?
      assert garbage.save_name == nil
      assert garbage.size > 0
    end

    test "a missing folder lists to nothing" do
      assert RenPy.list_saves("/nonexistent/game/folder") == []
    end
  end

  describe "tracked_files/2" do
    setup %{dir: dir} do
      game = Path.join(dir, "Game-1")
      RenPyFixtures.write_save(game, "1-1-LT1.save")
      RenPyFixtures.write_save(game, "auto-1-LT1.save")
      RenPyFixtures.write_save(game, "quick-1-LT1.save")
      RenPyFixtures.write_save(game, "_reload-1-LT1.save")
      File.write!(Path.join(game, "persistent"), "p")
      # Ren'Py 8.1+ keeps a replica of every save under sync/; only
      # top-level files may be tracked.
      RenPyFixtures.write_save(Path.join(game, "sync"), "1-1-LT1.save")
      {:ok, game: game}
    end

    test "skips autosaves, quicksaves, internals and subfolders by default", %{game: game} do
      assert RenPy.tracked_files(game) == [
               {"1-1-LT1.save", {:slot, 1, "1"}},
               {"persistent", :persistent}
             ]
    end

    test "includes autosaves and quicksaves when enabled", %{game: game} do
      names = game |> RenPy.tracked_files(sync_autosaves: true) |> Enum.map(&elem(&1, 0))
      assert names == ["1-1-LT1.save", "auto-1-LT1.save", "persistent", "quick-1-LT1.save"]
    end

    test "applies exclude patterns", %{game: game} do
      assert RenPy.tracked_files(game, exclude_patterns: ["1-*"]) == [
               {"persistent", :persistent}
             ]
    end
  end
end
