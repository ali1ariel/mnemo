defmodule Mnemo.GamesTest do
  use Mnemo.DataCase, async: false

  alias Mnemo.Games

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
end
