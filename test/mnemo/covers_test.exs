defmodule Mnemo.CoversTest do
  use Mnemo.DataCase, async: false

  alias Mnemo.{Covers, Games, RenPyFixtures}

  @png <<0x89, ?P, ?N, ?G, 13, 10, 26, 10>> <> "fake-png-body"
  @jpg <<0xFF, 0xD8, 0xFF>> <> "fake-jpeg-body"

  setup do
    base = Path.join(System.tmp_dir!(), "mnemo-covers-#{System.unique_integer([:positive])}")
    steam = Path.join(base, "Steam")
    cache = Path.join(base, "cover-cache")
    saves_root = Path.join(base, "renpy")
    File.mkdir_p!(saves_root)

    Application.put_env(:mnemo, :steam_roots, [steam])
    Application.put_env(:mnemo, :cover_cache_dir, cache)

    on_exit(fn ->
      Application.delete_env(:mnemo, :steam_roots)
      Application.delete_env(:mnemo, :cover_cache_dir)
      File.rm_rf!(base)
    end)

    {:ok, base: base, steam: steam, cache: cache, saves_root: saves_root}
  end

  defp install!(base, name) do
    install = Path.join([base, "steamapps", "common", name])
    File.mkdir_p!(install)
    install
  end

  defp steam_app!(steam, app_id, install_dir) do
    File.mkdir_p!(Path.join(steam, "steamapps"))

    File.write!(
      Path.join([steam, "steamapps", "appmanifest_#{app_id}.acf"]),
      ~s("AppState"\n{\n\t"appid"\t\t"#{app_id}"\n\t"installdir"\t\t"#{install_dir}"\n})
    )
  end

  defp steam_art!(steam, app_id, name, bytes) do
    dir = Path.join([steam, "appcache", "librarycache", app_id])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name), bytes)
  end

  defp game!(saves_root, attrs \\ %{}) do
    dir = Path.join(saves_root, "Game-1")
    RenPyFixtures.write_save(dir, "1-1-LT1.save")

    {:ok, game} =
      Games.enroll(
        Map.merge(%{save_directory: "Game-1", install_root: saves_root, name: "Some Game"}, attrs)
      )

    game
  end

  test "prefers the Steam capsule Steam already downloaded", ctx do
    install = install!(ctx.steam, "Some Game")
    steam_app!(ctx.steam, "42", "Some Game")
    steam_art!(ctx.steam, "42", "library_600x900.jpg", @jpg)
    File.write!(Path.join(install, "icon.png"), @png)

    game = game!(ctx.saves_root, %{install_path: install})

    assert {:ok, @jpg, "image/jpeg", :cover} = Covers.for_game(game)
    assert Covers.kind(game) == :cover
  end

  test "falls back to the icon the Ren'Py build ships", ctx do
    install = install!(ctx.steam, "Some Game")
    File.write!(Path.join(install, "icon.png"), @png)

    game = game!(ctx.saves_root, %{install_path: install})

    assert {:ok, @png, "image/png", :cover} = Covers.for_game(game)
    assert Covers.kind(game) == :cover
  end

  test "falls back to the save screenshot when the game has no artwork", ctx do
    game = game!(ctx.saves_root)

    assert {:ok, bytes, "image/png", :screenshot} = Covers.for_game(game)
    assert bytes == RenPyFixtures.png()
    # A save screenshot is an arbitrary frame, so it stays behind the blur.
    assert Covers.kind(game) == :screenshot
  end

  test "downloaded art beats every local source", ctx do
    install = install!(ctx.steam, "Some Game")
    File.write!(Path.join(install, "icon.png"), @png)
    game = game!(ctx.saves_root, %{install_path: install})

    File.mkdir_p!(ctx.cache)
    File.write!(Path.join(ctx.cache, "#{game.id}.jpg"), @jpg)

    assert {:ok, @jpg, "image/jpeg", :cover} = Covers.for_game(game)
    assert Covers.kind(game) == :cover

    Covers.clear_cache(game.id)
    assert {:ok, @png, "image/png", :cover} = Covers.for_game(game)
    assert Covers.kind(game) == :cover
  end

  test "a game with nothing anywhere reports no cover", ctx do
    dir = Path.join(ctx.saves_root, "Empty-1")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "persistent"), "p")

    {:ok, game} = Games.enroll(%{save_directory: "Empty-1", install_root: ctx.saves_root})

    assert Covers.for_game(game) == :none
  end

  describe "steam_app_id/1" do
    test "maps an install directory back to its app id", ctx do
      install = install!(ctx.steam, "Some Game")
      steam_app!(ctx.steam, "42", "Some Game")

      assert Covers.steam_app_id(install) == {:ok, "42"}
    end

    test "reports games Steam does not know about", ctx do
      install = install!(ctx.steam, "Downloaded From Itch")
      assert Covers.steam_app_id(install) == {:error, :not_found}
    end

    test "does not confuse two games whose names share a prefix", ctx do
      steam_app!(ctx.steam, "10", "Some Game")
      steam_app!(ctx.steam, "20", "Some Game Deluxe")

      assert Covers.steam_app_id(install!(ctx.steam, "Some Game Deluxe")) == {:ok, "20"}
      assert Covers.steam_app_id(install!(ctx.steam, "Some Game")) == {:ok, "10"}
    end
  end

  describe "for_scan_entry/1" do
    test "uses install artwork before the folder is enrolled", ctx do
      install = install!(ctx.steam, "Some Game")
      steam_app!(ctx.steam, "42", "Some Game")
      steam_art!(ctx.steam, "42", "header.jpg", @jpg)

      dir = Path.join(ctx.saves_root, "Game-1")
      RenPyFixtures.write_save(dir, "1-1-LT1.save")

      assert {:ok, @jpg, "image/jpeg", :cover} =
               Covers.for_scan_entry(%{path: dir, install: install})
    end

    test "falls back to the screenshot for a folder with no install", ctx do
      dir = Path.join(ctx.saves_root, "Game-1")
      RenPyFixtures.write_save(dir, "1-1-LT1.save")

      assert {:ok, bytes, "image/png", :screenshot} =
               Covers.for_scan_entry(%{path: dir, install: nil})

      assert bytes == RenPyFixtures.png()
    end
  end
end
