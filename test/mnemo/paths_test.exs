defmodule Mnemo.PathsTest do
  use ExUnit.Case, async: false

  alias Mnemo.Paths

  setup do
    on_exit(fn -> Application.delete_env(:mnemo, :windows_paths) end)
    :ok
  end

  defp long(n), do: "C:\\" <> String.duplicate("a", n)

  test "everywhere but Windows there is nothing to enforce" do
    Application.put_env(:mnemo, :windows_paths, false)
    assert Paths.check_length([long(400)]) == :ok
  end

  test "names the paths Windows would reject, and only those" do
    Application.put_env(:mnemo, :windows_paths, true)

    short = long(50)
    over = long(300)

    assert {:error, :path_too_long, detail} = Paths.check_length([short, over])
    assert detail.paths == [over]
    assert detail.limit == 260
  end

  test "a path exactly at the limit is allowed" do
    Application.put_env(:mnemo, :windows_paths, true)
    at_limit = String.duplicate("a", 260)

    assert String.length(at_limit) == 260
    assert Paths.check_length([at_limit]) == :ok
    assert {:error, :path_too_long, _} = Paths.check_length([at_limit <> "a"])
  end

  test "the real Ren'Py layout has room to spare" do
    Application.put_env(:mnemo, :windows_paths, true)

    path =
      "C:\\Users\\alisson\\AppData\\Roaming\\RenPy" <>
        "\\CampBuddyScoutmastersSeason-1608150621.mnemo-restore-123456789" <>
        "\\1-Save Slot 10-LT1.save"

    assert Paths.check_length([path]) == :ok
    assert String.length(path) < 200
  end
end
