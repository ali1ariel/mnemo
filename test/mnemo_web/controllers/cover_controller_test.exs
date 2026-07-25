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

  describe "slot screenshots" do
    setup %{root: root} do
      dir = Path.join(root, "Game-1")
      RenPyFixtures.write_save(dir, "1-Save Slot 9-LT1.save")
      RenPyFixtures.write_garbage_save(dir, "2-1-LT1.save")
      File.write!(Path.join(dir, "persistent"), "p")
      {:ok, game} = Games.enroll(%{save_directory: "Game-1", install_root: root})
      {:ok, game: game}
    end

    test "serves the screenshot of a named slot", %{conn: conn, game: game} do
      conn = get(conn, ~p"/covers/#{game.id}/#{"1-Save Slot 9-LT1.save"}")
      assert response(conn, 200) == RenPyFixtures.png()
      assert response_content_type(conn, :png) =~ "image/png"
    end

    test "404 for corrupt saves, non-slot files and traversal attempts", %{
      conn: conn,
      game: game
    } do
      assert conn |> get(~p"/covers/#{game.id}/#{"2-1-LT1.save"}") |> response(404)
      assert conn |> get(~p"/covers/#{game.id}/#{"persistent"}") |> response(404)
      assert conn |> get(~p"/covers/#{game.id}/#{"9-9-LT1.save"}") |> response(404)
      assert conn |> get(~p"/covers/#{game.id}/#{"../persistent"}") |> response(404)
      assert conn |> get(~p"/covers/#{game.id}/#{"../../etc/passwd"}") |> response(404)
    end
  end

  describe "scan previews for unenrolled games" do
    setup %{root: root} do
      Application.put_env(:mnemo, :renpy_roots, [root])
      on_exit(fn -> Application.put_env(:mnemo, :renpy_roots, []) end)

      dir = Path.join(root, "Unenrolled-1")
      RenPyFixtures.write_save(dir, "1-Save Slot 9-LT1.save")
      RenPyFixtures.write_garbage_save(dir, "2-1-LT1.save")
      File.write!(Path.join(dir, "persistent"), "p")
      :ok
    end

    test "serves a slot screenshot without any enrolled game", %{conn: conn, root: root} do
      conn =
        get(
          conn,
          ~p"/scan/preview?root=#{root}&dir=Unenrolled-1&file=#{"1-Save Slot 9-LT1.save"}"
        )

      assert response(conn, 200) == RenPyFixtures.png()
      assert response_content_type(conn, :png) =~ "image/png"
    end

    test "404 outside the known roots and for escaping names", %{conn: conn, root: root} do
      assert conn
             |> get(~p"/scan/preview?root=/etc&dir=Unenrolled-1&file=#{"1-Save Slot 9-LT1.save"}")
             |> response(404)

      assert conn
             |> get(
               ~p"/scan/preview?root=#{root}&dir=#{"../outside"}&file=#{"1-Save Slot 9-LT1.save"}"
             )
             |> response(404)

      assert conn
             |> get(~p"/scan/preview?root=#{root}&dir=#{".."}&file=#{"1-Save Slot 9-LT1.save"}")
             |> response(404)

      assert conn
             |> get(~p"/scan/preview?root=#{root}&dir=Unenrolled-1&file=persistent")
             |> response(404)

      assert conn
             |> get(~p"/scan/preview?root=#{root}&dir=Unenrolled-1&file=#{"../../secret"}")
             |> response(404)

      assert conn
             |> get(~p"/scan/preview?root=#{root}&dir=Unenrolled-1&file=#{"2-1-LT1.save"}")
             |> response(404)

      assert conn |> get(~p"/scan/preview") |> response(404)
    end
  end
end
