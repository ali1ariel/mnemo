defmodule Mnemo.Paths do
  @moduledoc """
  What the operating system will refuse to write, asked before writing.

  Windows still enforces a 260 character limit on ordinary paths. The
  documented escape is the `\\\\?\\` prefix, which mnemo does **not**
  use, and that is a decision rather than an omission:

    * the prefix requires backslash-only, fully normalised, absolute
      paths, while every path here is built with `Path.join/2`, which
      emits forward slashes — adopting it means replacing path
      construction throughout the code that overwrites saves;
    * the paths this application actually builds leave large headroom.
      `%APPDATA%\\RenPy\\<save_directory>\\<page>-<name>-LT1.save` plus a
      staging suffix measures around 125 characters for a real Ren'Py
      game, and the Proton layout that does get long is Linux-side, where
      no such limit exists.

    Rewriting path handling untested, in the module that replaces
    someone's saves, to cover a case with 135 characters of slack is the
    worse trade. So the limit is checked and named instead: a refusal
    that says which path was too long beats `:enametoolong` surfacing
    from the middle of a restore.
  """

  @windows_limit 260

  @doc """
  `:ok`, or the paths that Windows would reject.

  Everywhere else this always passes — ext4, APFS and NTFS through the
  Win32 long path setting all take far longer names.
  """
  def check_length(paths) do
    if windows?() do
      case Enum.filter(paths, &(String.length(&1) > @windows_limit)) do
        [] -> :ok
        long -> {:error, :path_too_long, %{paths: long, limit: @windows_limit}}
      end
    else
      :ok
    end
  end

  @doc """
  Whether this machine enforces the Windows path limit.

  `config :mnemo, :windows_paths, true` forces the answer, so the branch
  can be exercised from a machine that is not Windows.
  """
  def windows? do
    case Application.get_env(:mnemo, :windows_paths) do
      nil -> match?({:win32, _}, :os.type())
      forced -> forced
    end
  end
end
