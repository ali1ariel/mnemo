defmodule MnemoWeb.LibraryLiveTest do
  use MnemoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mnemo.Drive.Fake
  alias Mnemo.{Games, RenPyFixtures}

  setup do
    Fake.reset()
    root = Path.join(System.tmp_dir!(), "mnemo-lib-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "renders the empty state with an enroll link", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "No games enrolled yet"
    assert has_element?(view, "#empty-enroll-link")
    assert has_element?(view, "#drive-status")
  end

  test "renders an enrolled game with its sync control", %{conn: conn, root: root} do
    dir = Path.join(root, "MyGame-123")
    RenPyFixtures.write_save(dir, "1-1-LT1.save")

    {:ok, game} =
      Games.enroll(%{save_directory: "MyGame-123", install_root: root, name: "My Game"})

    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "My Game"
    assert has_element?(view, "#game-#{game.id}")
    assert has_element?(view, "#sync-#{game.id}")
  end

  test "the sync button drives a full cycle against the fake drive", %{conn: conn, root: root} do
    dir = Path.join(root, "MyGame-123")
    RenPyFixtures.write_save(dir, "1-1-LT1.save")
    File.write!(Path.join(dir, "persistent"), "p")

    {:ok, game} =
      Games.enroll(%{save_directory: "MyGame-123", install_root: root, name: "My Game"})

    Mnemo.Game.subscribe()

    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#sync-#{game.id}") |> render_click()

    game_id = game.id
    assert_receive {:game, ^game_id, %{status: :ok}}, 5_000

    _ = :sys.get_state(view.pid)
    html = render(view)
    assert html =~ "Generation 1 uploaded."
    assert Games.get!(game.id).last_generation_seen == 1
  end
end
