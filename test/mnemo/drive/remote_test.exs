defmodule Mnemo.Drive.RemoteTest do
  use Mnemo.DataCase, async: false

  alias Mnemo.Drive.{Fake, Remote}
  alias Mnemo.Games

  setup do
    Fake.reset()
    {:ok, layout} = Remote.ensure_layout(Fake)
    {:ok, layout: layout}
  end

  defp enroll!(attrs \\ %{}) do
    {:ok, game} =
      Games.enroll(
        Map.merge(
          %{save_directory: "MyGame-123", install_root: "appdata", name: "My Game"},
          attrs
        )
      )

    game
  end

  defp game_json(folder_id) do
    {:ok, meta} = Fake.find_child(folder_id, "game.json")
    {:ok, raw} = Fake.download(meta.id)
    Jason.decode!(raw)
  end

  test "a fresh game gets game.json describing it", %{layout: layout} do
    game = enroll!()

    {:ok, remote} = Remote.ensure_game(Fake, layout.games_id, game)

    assert %{"save_directory" => "MyGame-123", "name" => "My Game", "id" => id} =
             game_json(remote.folder_id)

    assert id == game.id
  end

  test "a folder left without game.json by a partial failure heals itself", %{layout: layout} do
    game = enroll!()

    # Exactly what a network blip between create_folder and the game.json
    # upload leaves behind.
    {:ok, orphan} = Fake.create_folder(layout.games_id, game.id)
    assert {:ok, nil} = Fake.find_child(orphan.id, "game.json")

    {:ok, remote} = Remote.ensure_game(Fake, layout.games_id, game)

    assert remote.folder_id == orphan.id
    assert %{"save_directory" => "MyGame-123"} = game_json(orphan.id)
  end

  test "renaming a game propagates to game.json on the next sync", %{layout: layout} do
    game = enroll!()
    {:ok, remote} = Remote.ensure_game(Fake, layout.games_id, game)
    assert game_json(remote.folder_id)["name"] == "My Game"

    {:ok, renamed} = Games.update_game(game, %{name: "Renamed Game"})
    {:ok, remote} = Remote.ensure_game(Fake, layout.games_id, renamed)

    assert game_json(remote.folder_id)["name"] == "Renamed Game"
  end

  test "a second machine finds the game by save_directory alone", %{layout: layout} do
    first = enroll!()
    {:ok, remote} = Remote.ensure_game(Fake, layout.games_id, first)

    # Same game, different install: new uuid, no cached folder id.
    other_machine = %{first | id: Ecto.UUID.generate(), remote_folder_id: nil, name: nil}
    {:ok, adopted} = Remote.ensure_game(Fake, layout.games_id, other_machine)

    assert adopted.folder_id == remote.folder_id
  end

  test "folders created before readable names are still adopted", %{layout: layout} do
    game = enroll!()

    legacy = Jason.encode!(%{"id" => game.id, "save_directory" => "MyGame-123", "name" => "Old"})
    {:ok, folder} = Fake.create_folder(layout.games_id, game.id)
    {:ok, _} = Fake.upload(folder.id, "game.json", legacy, "application/json")

    {:ok, remote} = Remote.ensure_game(Fake, layout.games_id, game)
    assert remote.folder_id == folder.id
  end
end
