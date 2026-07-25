defmodule Mnemo.Sync.Overwrite do
  @moduledoc """
  The steps every overwrite of a live save folder goes through.

  Rule 3 — an overwrite must never be irreversible — has two ways in:
  restoring a generation and importing an archive. Both publish the
  current state as a generation first, build the replacement in a sibling
  directory, and put it in place with two renames. That is the part which
  destroys data when it is wrong, so it lives here once instead of twice.

  The ordering that matters: the backup folder is dropped only once a
  safety generation exists. An overwrite never finishes with both the
  generation missing and the backup gone.
  """

  require Logger

  alias Mnemo.Games
  alias Mnemo.Sync.Engine

  @doc """
  Publish what is on disk now, so the overwrite is undoable through
  normal history.

  Best effort by design: a diverged lineage refuses new generations, and
  that is exactly the case where the backup folder has to be kept. The
  returned tag says which happened.
  """
  def safety_generation(game, opts, notify) do
    if Keyword.get(opts, :safety_generation, true) do
      notify.(:safety_snapshot)

      case Engine.run(game) do
        {:ok, :no_changes} ->
          {:ok, reload(game), :current}

        {:ok, %{generation: number}} ->
          {:ok, reload(game), {:published, number}}

        {:error, tag, detail} ->
          Logger.warning("safety generation failed: #{inspect({tag, detail})}")
          {:ok, reload(game), {:unavailable, tag}}
      end
    else
      {:ok, game, {:unavailable, :skipped}}
    end
  end

  defp reload(game), do: Games.get(game.id) || game

  @doc """
  A staging directory beside the game folder.

  Never the system temp dir: the swap is a rename, and rename across
  filesystems fails with `:exdev`. `/tmp` is a different filesystem on
  most Linux setups.
  """
  def staging_dir(path, tag) do
    path <> ".mnemo-#{tag}-#{System.unique_integer([:positive])}"
  end

  def backup_path(path) do
    stamp =
      DateTime.utc_now()
      |> DateTime.to_iso8601(:basic)
      |> String.replace(~r/[^0-9]/, "")

    path <> ".bak-#{stamp}"
  end

  @doc """
  Move `staging` into `path`, keeping the old folder as a backup.

  Two renames, so the live folder is never half-written. If the second
  fails the first is undone before returning — otherwise a failed
  overwrite would leave the game with no saves at all.
  """
  def swap(path, staging) do
    backup = backup_path(path)

    with :ok <- rename(path, backup, :backup_failed) do
      case File.rename(staging, path) do
        :ok ->
          {:ok, backup}

        {:error, reason} ->
          rolled_back = File.rename(backup, path)

          {:error, :swap_failed,
           %{reason: reason, backup: backup, rolled_back: rolled_back == :ok}}
      end
    end
  end

  def rename(from, to, tag) do
    case File.rename(from, to) do
      :ok -> :ok
      {:error, reason} -> {:error, tag, %{reason: reason, from: from, to: to}}
    end
  end

  @doc """
  Drop the backup folder when the previous state is recorded elsewhere,
  keep it when it is not. Returns the path still on disk, or nil.
  """
  def settle_backup(backup, safety) do
    case safety do
      # Either a new generation captured the previous state, or nothing
      # had changed and the existing head already plays that role.
      {:published, _} -> discard(backup)
      :current -> discard(backup)
      {:unavailable, _} -> backup
    end
  end

  defp discard(backup) do
    case File.rm_rf(backup) do
      {:ok, _} ->
        nil

      {:error, reason, _} ->
        Logger.warning("could not remove backup #{backup}: #{inspect(reason)}")
        backup
    end
  end
end
