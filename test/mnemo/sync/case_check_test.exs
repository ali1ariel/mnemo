defmodule Mnemo.Sync.CaseCheckTest do
  use ExUnit.Case, async: false

  alias Mnemo.Sync.CaseCheck

  setup do
    dir = Path.join(System.tmp_dir!(), "mnemo-case-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      Application.delete_env(:mnemo, :case_insensitive_filesystem)
      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  describe "collisions/1" do
    test "finds names that differ only in case" do
      assert CaseCheck.collisions(["1-Save-LT1.save", "1-save-LT1.save"]) ==
               [["1-Save-LT1.save", "1-save-LT1.save"]]
    end

    test "a repeated name is not a collision" do
      assert CaseCheck.collisions(["persistent", "persistent"]) == []
    end

    test "reports each colliding group separately" do
      names = ["a.save", "A.save", "b.save", "B.save", "c.save"]
      assert CaseCheck.collisions(names) == [["A.save", "a.save"], ["B.save", "b.save"]]
    end

    test "an ordinary set of Ren'Py names is clean" do
      assert CaseCheck.collisions([
               "1-1-LT1.save",
               "1-Save Slot 2-LT1.save",
               "auto-1-LT1.save",
               "persistent"
             ]) == []
    end
  end

  describe "case_insensitive?/1" do
    test "answers for the filesystem the directory is actually on", %{dir: dir} do
      # Asked of the filesystem, not the OS: this is what makes a
      # case-sensitive volume on Windows come out right.
      assert is_boolean(CaseCheck.case_insensitive?(dir))
    end

    test "leaves nothing behind", %{dir: dir} do
      CaseCheck.case_insensitive?(dir)
      assert File.ls!(dir) == []
    end

    test "a directory that does not exist is not reported as folding case" do
      refute CaseCheck.case_insensitive?("/nonexistent-mnemo-probe")
    end

    test "can be forced, so the Windows branch is reachable from here", %{dir: dir} do
      Application.put_env(:mnemo, :case_insensitive_filesystem, true)
      assert CaseCheck.case_insensitive?(dir)

      Application.put_env(:mnemo, :case_insensitive_filesystem, false)
      refute CaseCheck.case_insensitive?(dir)
    end
  end

  describe "check/2" do
    test "passes colliding names on a case-sensitive filesystem", %{dir: dir} do
      Application.put_env(:mnemo, :case_insensitive_filesystem, false)
      assert CaseCheck.check(dir, ["a.save", "A.save"]) == :ok
    end

    test "refuses them where they would fold together", %{dir: dir} do
      Application.put_env(:mnemo, :case_insensitive_filesystem, true)

      assert {:error, :case_collision, detail} = CaseCheck.check(dir, ["a.save", "A.save"])
      assert detail.groups == [["A.save", "a.save"]]
      assert detail.path == dir
    end

    test "a clean set passes anywhere", %{dir: dir} do
      Application.put_env(:mnemo, :case_insensitive_filesystem, true)
      assert CaseCheck.check(dir, ["1-1-LT1.save", "persistent"]) == :ok
    end
  end
end
