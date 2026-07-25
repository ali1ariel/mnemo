defmodule Mnemo.Sync.CaseCheck do
  @moduledoc """
  Stop two saves whose names differ only in case from becoming one.

  ext4 keeps `1-Save-LT1.save` and `1-save-LT1.save` apart; NTFS and the
  default macOS volume do not. Restoring such a generation on Windows
  writes both to the same file, and the interface reports success over a
  slot that is simply gone — one of the few ways mnemo can lose data
  without anything appearing to fail.

  Whether the target actually folds case is asked of the filesystem
  rather than of the operating system: a case-sensitive volume mounted on
  Windows and a case-sensitive macOS volume are both real, and `:os.type`
  would be wrong about both.
  """

  @doc """
  Names that would collapse into one another on a case-insensitive
  filesystem, as a list of the colliding groups.

  Empty when the set is safe anywhere.
  """
  def collisions(names) do
    names
    |> Enum.group_by(&String.downcase/1)
    |> Enum.filter(fn {_folded, group} -> length(Enum.uniq(group)) > 1 end)
    |> Enum.map(fn {_folded, group} -> group |> Enum.uniq() |> Enum.sort() end)
    |> Enum.sort()
  end

  @doc """
  `:ok`, or the collisions that would be lost writing `names` into `dir`.

  Safe by construction on a case-sensitive filesystem, so the probe comes
  first and the grouping only runs when it can matter.
  """
  def check(dir, names) do
    if case_insensitive?(dir) do
      case collisions(names) do
        [] -> :ok
        groups -> {:error, :case_collision, %{groups: groups, path: dir}}
      end
    else
      :ok
    end
  end

  @doc """
  Whether `dir` folds case, asked by writing a file and looking for it
  under another spelling.

  A directory that cannot be written to answers `false`: the caller is
  about to fail on the write anyway, and reporting a case collision for
  a permissions problem would send someone the wrong way.

  `config :mnemo, :case_insensitive_filesystem, true` forces the answer.
  That exists so the behaviour a Windows user would get can be rehearsed
  on a case-sensitive machine — otherwise the branch that protects them
  is the one branch nobody here can run.
  """
  def case_insensitive?(dir) do
    case Application.get_env(:mnemo, :case_insensitive_filesystem) do
      nil -> probe(dir)
      forced -> forced
    end
  end

  defp probe(dir) do
    probe = Path.join(dir, ".mnemo-case-#{System.unique_integer([:positive])}")
    upper = probe <> "-A"
    lower = probe <> "-a"

    case File.write(upper, "") do
      :ok ->
        try do
          File.exists?(lower)
        after
          File.rm(upper)
        end

      {:error, _} ->
        false
    end
  end
end
