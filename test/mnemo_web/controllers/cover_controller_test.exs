defmodule MnemoWeb.CoverControllerTest do
  use MnemoWeb.ConnCase, async: false

  alias Mnemo.{Games, RenPyFixtures}

  setup do
    root = Path.join(System.tmp_dir!(), "mnemo-cover-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "serves the screenshot of the most recent save", %{conn: conn, root: root} do
    dir = Path.join(root, "Game-1")
    RenPyFixtures.write_save(dir, "1-1-LT1.save")
    {:ok, game} = Games.enroll(%{save_directory: "Game-1", install_root: root})

    conn = get(conn, ~p"/covers/#{game.id}")

    assert response(conn, 200) == RenPyFixtures.png()
    assert response_content_type(conn, :png) =~ "image/png"
  end

  test "404 when the game has no saves", %{conn: conn, root: root} do
    File.mkdir_p!(Path.join(root, "Game-1"))
    {:ok, game} = Games.enroll(%{save_directory: "Game-1", install_root: root})

    conn = get(conn, ~p"/covers/#{game.id}")
    assert response(conn, 404)
  end

  test "404 for unknown or malformed ids", %{conn: conn} do
    assert conn |> get(~p"/covers/#{Ecto.UUID.generate()}") |> response(404)
    assert conn |> get("/covers/not-a-uuid") |> response(404)
  end
end
