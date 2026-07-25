defmodule Mnemo.Sync.Mirror do
  @moduledoc """
  Carry a restore or an import through to the other places Ren'Py keeps
  the same saves.

  Without this, removing a slot half works. mnemo deletes it from the
  folder it tracks, the packaged copy under `<gamedir>/saves` keeps it,
  and `MultiLocation.load` reads whichever is newest — so the slot the
  player just watched disappear is back the next time they open the game.
  Nothing was lost, but the interface said something that is not true.

  Two rules shape how carefully this goes:

    * **Rule 1 holds.** A mirror is written to only if it already exists.
      No location is ever created here.
    * **Rule 3 holds.** A mirror is only touched when it still matches the
      folder mnemo tracked, checked *before* the swap. A mirror that
      drifted holds bytes no generation captured, and overwriting those
      would be an overwrite with nothing to come back to — so it is left
      alone and reported instead.
  """

  require Logger

  alias Mnemo.RenPy

  @doc """
  Decide which mirrors may be updated, from the state as it is now.

  Must run before the folder is replaced: afterwards there is nothing
  left to compare a mirror against.
  """
  def plan(game, path) do
    tracked = signature(game, path)

    {safe, diverged} =
      game
      |> RenPy.other_locations()
      |> Enum.split_with(fn mirror -> signature(game, mirror) == tracked end)

    %{safe: safe, diverged: diverged}
  end

  # Name and size, the same evidence `RenPy.group_mirrors/1` uses to
  # decide two folders are the same game. Hashing multi-megabyte archives
  # to answer a question that name and size already answer would cost far
  # more for no extra certainty.
  defp signature(game, path) do
    path
    |> RenPy.tracked_files(
      sync_autosaves: game.sync_autosaves,
      exclude_patterns: game.exclude_patterns || []
    )
    |> Enum.flat_map(fn {name, _slot} ->
      case File.stat(Path.join(path, name)) do
        {:ok, %{size: size}} -> [{name, size}]
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  @doc """
  Make the safe mirrors match `path` again, after the swap.

  Best effort on purpose: the tracked folder is already correct and
  published, so a mirror that cannot be written must not turn a finished
  restore into a failure. Every outcome is reported so the interface can
  say what happened rather than imply it all worked.
  """
  def apply(plan, game, path) do
    results = Enum.map(plan.safe, &update(game, path, &1))

    %{
      updated: Enum.filter(results, &(&1.error == nil)),
      failed: Enum.reject(results, &(&1.error == nil)),
      diverged: plan.diverged
    }
  end

  defp update(game, path, mirror) do
    desired = names(game, path)
    present = names(game, mirror)

    with {:ok, removed} <- remove(mirror, MapSet.difference(present, desired)),
         {:ok, copied} <- copy(path, mirror, desired) do
      %{path: mirror, removed: removed, copied: copied, error: nil}
    else
      {:error, reason} ->
        Logger.warning("could not update the mirrored saves at #{mirror}: #{inspect(reason)}")
        %{path: mirror, removed: 0, copied: 0, error: reason}
    end
  end

  defp names(game, path) do
    path
    |> RenPy.tracked_files(
      sync_autosaves: game.sync_autosaves,
      exclude_patterns: game.exclude_patterns || []
    )
    |> MapSet.new(fn {name, _slot} -> name end)
  end

  defp remove(mirror, names) do
    Enum.reduce_while(names, {:ok, 0}, fn name, {:ok, count} ->
      case File.rm(Path.join(mirror, name)) do
        :ok -> {:cont, {:ok, count + 1}}
        {:error, :enoent} -> {:cont, {:ok, count}}
        {:error, reason} -> {:halt, {:error, %{file: name, reason: reason}}}
      end
    end)
  end

  defp copy(path, mirror, names) do
    Enum.reduce_while(names, {:ok, 0}, fn name, {:ok, count} ->
      case File.cp(Path.join(path, name), Path.join(mirror, name)) do
        :ok -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, %{file: name, reason: reason}}}
      end
    end)
  end
end
