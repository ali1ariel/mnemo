defmodule Mnemo.Sync.Restore do
  @moduledoc """
  Bring the files of a generation back to disk.

  This is the only code in mnemo that overwrites the player's saves, so
  every step is ordered to survive the machine dying halfway through:

    * the current state is published as a new generation first, which is
      what makes the restore itself undoable through normal history;
    * the new files are staged in a sibling directory on the same volume
      and are fully downloaded, hash-checked and zip-validated before
      anything live is touched;
    * the swap is two renames — the live folder becomes
      `<name>.bak-<timestamp>`, the staging folder takes its place;
    * the backup is deleted only once a safety generation exists. When it
      could not be published (a conflicting lineage, no network), the
      folder stays and the caller is told where it is.

  The consequence worth stating: a restore never finishes with both the
  safety generation missing and the backup gone.

  Files outside the synced set — autosaves while `sync_autosaves` is off,
  Ren'Py's own `sync/` folder, anything the player dropped in there — are
  carried across untouched. A manifest describes the tracked files, not
  the whole directory, so it must never be read as "delete the rest".
  """

  alias Mnemo.Drive.{Backend, Remote}
  alias Mnemo.{Games, RenPy, Sync}
  alias Mnemo.Sync.Overwrite

  # Ren'Py rewrites `persistent` on exit, so a folder still being written
  # to is the signal that the game did not actually close.
  @quiet_seconds 60
  @download_concurrency 3

  @doc """
  Run the guards without touching anything.

  Callers use this to answer "is this allowed?" synchronously, before
  handing the slow part to a task.
  """
  def precheck(game, opts \\ []) do
    path = RenPy.game_path(game)

    with :ok <- check_target(path),
         :ok <- check_confirmation(opts),
         do: check_quiescence(path, opts)
  end

  def run(game, number, opts \\ [], notify \\ fn _phase -> :ok end) do
    path = RenPy.game_path(game)

    with :ok <- precheck(game, opts),
         {:ok, game, safety} <- Overwrite.safety_generation(game, opts, notify),
         {:ok, ctx} <- resolve_remote(game),
         {:ok, files} <- fetch_manifest(ctx, game, number),
         {:ok, head} <- observe_head(ctx) do
      notify.(:downloading)
      staging = Overwrite.staging_dir(path, "restore")

      try do
        with {:ok, _} <- stage(ctx, game, path, staging, files),
             {:ok, backup} <- swap(path, staging, notify) do
          finish(game, number, head, safety, backup)
        end
      after
        File.rm_rf(staging)
      end
    end
  end

  ## Guards

  defp check_target(nil), do: {:error, :no_root, %{}}

  defp check_target(path) do
    # Rule 1: mnemo never creates a save directory. If the folder is gone
    # the game is not installed here and there is nothing to restore into.
    if File.dir?(path), do: :ok, else: {:error, :missing_folder, %{path: path}}
  end

  defp check_confirmation(opts) do
    if Keyword.get(opts, :confirmed_closed, false) do
      :ok
    else
      {:error, :confirmation_required, %{}}
    end
  end

  defp check_quiescence(path, opts) do
    if Keyword.get(opts, :force, false) do
      :ok
    else
      case seconds_since_write(path) do
        nil ->
          :ok

        seconds when seconds >= @quiet_seconds ->
          :ok

        seconds ->
          {:error, :game_may_be_running,
           %{seconds_since_write: seconds, quiet_seconds: @quiet_seconds}}
      end
    end
  end

  @doc "Seconds since the most recent write anywhere in the folder, or nil if empty."
  def seconds_since_write(path) do
    case newest_mtime(path) do
      nil -> nil
      mtime -> DateTime.diff(DateTime.utc_now(), mtime)
    end
  end

  defp newest_mtime(path) do
    path
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.flat_map(fn entry ->
      case File.stat(entry, time: :posix) do
        {:ok, %{type: :regular, mtime: mtime}} -> [DateTime.from_unix!(mtime)]
        _ -> []
      end
    end)
    |> Enum.max(DateTime, fn -> nil end)
  end

  ## Remote

  defp resolve_remote(game) do
    backend = Backend.impl()

    with {:ok, layout} <- drive(Remote.ensure_layout(backend), :ensure_layout),
         {:ok, remote} <- drive(Remote.ensure_game(backend, layout.games_id, game), :ensure_game) do
      {:ok, %{backend: backend, remote: remote}}
    end
  end

  defp fetch_manifest(ctx, game, number) do
    case Sync.get_generation(game.id, number) do
      %{manifest: files} when is_list(files) and files != [] ->
        {:ok, files}

      _ ->
        with {:ok, manifest} <-
               drive(
                 Remote.get_manifest(ctx.backend, ctx.remote.generations_id, number),
                 :get_manifest
               ) do
          case manifest["files"] do
            files when is_list(files) and files != [] -> {:ok, files}
            _ -> {:error, :empty_generation, %{generation: number}}
          end
        end
    end
  end

  # After a restore this device has observed the remote up to its head,
  # whichever generation the files came from. Recording anything lower
  # would make the very next sync report a phantom conflict.
  defp observe_head(ctx) do
    with {:ok, numbers} <-
           drive(
             Remote.list_generation_numbers(ctx.backend, ctx.remote.generations_id),
             :list_generations
           ) do
      {:ok, Enum.max(numbers, fn -> 0 end)}
    end
  end

  ## Staging

  defp stage(ctx, game, path, staging, files) do
    with :ok <- copy_current(path, staging),
         :ok <- clear_tracked(game, staging),
         :ok <- download_files(ctx, staging, files),
         :ok <- validate_staged(staging, files) do
      {:ok, staging}
    end
  end

  # Everything is carried over first so that files outside the synced set
  # survive; the tracked ones are then removed and rewritten from the
  # manifest.
  defp copy_current(path, staging) do
    File.rm_rf(staging)

    case File.cp_r(path, staging) do
      {:ok, _} -> :ok
      {:error, reason, file} -> {:error, :staging_failed, %{reason: reason, file: file}}
    end
  end

  defp clear_tracked(game, staging) do
    tracked =
      RenPy.tracked_files(staging,
        sync_autosaves: game.sync_autosaves,
        exclude_patterns: game.exclude_patterns || []
      )

    Enum.reduce_while(tracked, :ok, fn {rel, _slot}, :ok ->
      case File.rm(Path.join(staging, rel)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, :staging_failed, %{reason: reason, file: rel}}}
      end
    end)
  end

  defp download_files(ctx, staging, files) do
    results =
      Task.Supervisor.async_stream_nolink(
        Mnemo.TaskSupervisor,
        Enum.uniq_by(files, & &1["sha256"]),
        fn file -> fetch_blob(ctx, file) end,
        max_concurrency: @download_concurrency,
        timeout: 300_000,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.to_list()

    failures =
      Enum.flat_map(results, fn
        {:ok, {:ok, _sha, _content}} -> []
        {:ok, {:error, detail}} -> [detail]
        {:exit, reason} -> [%{reason: {:exit, reason}}]
      end)

    if failures == [] do
      blobs = Map.new(results, fn {:ok, {:ok, sha, content}} -> {sha, content} end)
      write_files(staging, files, blobs)
    else
      {:error, :download_failed, %{failures: failures}}
    end
  end

  defp fetch_blob(ctx, file) do
    sha = file["sha256"]

    case Remote.download_blob(ctx.backend, ctx.remote.blobs_id, sha) do
      {:ok, content} ->
        # A blob is addressed by its content hash, so a mismatch means the
        # bytes are not what the manifest promised. Never let those land.
        if Base.encode16(:crypto.hash(:sha256, content), case: :lower) == sha do
          {:ok, sha, content}
        else
          {:error, %{file: file["rel_path"], sha256: sha, reason: :checksum_mismatch}}
        end

      {:error, reason} ->
        {:error, %{file: file["rel_path"], sha256: sha, reason: reason}}
    end
  end

  defp write_files(staging, files, blobs) do
    Enum.reduce_while(files, :ok, fn file, :ok ->
      target = Path.join(staging, file["rel_path"])

      with :ok <- File.mkdir_p(Path.dirname(target)),
           :ok <- File.write(target, Map.fetch!(blobs, file["sha256"])) do
        {:cont, :ok}
      else
        {:error, reason} ->
          {:halt, {:error, :staging_failed, %{reason: reason, file: file["rel_path"]}}}
      end
    end)
  end

  # Rule 4 applies in this direction too: a save that will not open as a
  # zip must never reach the live folder.
  defp validate_staged(staging, files) do
    files
    |> Enum.filter(&String.ends_with?(&1["rel_path"], ".save"))
    |> Enum.reduce_while(:ok, fn file, :ok ->
      case RenPy.validate_save(Path.join(staging, file["rel_path"])) do
        :ok -> {:cont, :ok}
        {:error, detail} -> {:halt, {:error, :invalid_save, detail}}
      end
    end)
  end

  ## Swap

  defp swap(path, staging, notify) do
    notify.(:swapping)
    Overwrite.swap(path, staging)
  end

  ## Commit

  defp finish(game, number, head, safety, backup) do
    {:ok, _game} = Games.set_last_generation_seen(game, head)

    {:ok,
     %{
       generation: number,
       safety: safety,
       backup: Overwrite.settle_backup(backup, safety),
       last_generation_seen: head
     }}
  end

  ## Backups

  @doc """
  Backup folders left next to a game's save folder.

  A leftover backup means a restore did not get to clean up — either it
  died mid-flight or the safety generation never made it out — so the
  interface offers a rollback instead of quietly hiding them.
  """
  def list_backups(game) do
    with path when is_binary(path) <- RenPy.game_path(game),
         parent = Path.dirname(path),
         prefix = Path.basename(path) <> ".bak-",
         {:ok, names} <- File.ls(parent) do
      for name <- names,
          String.starts_with?(name, prefix),
          full = Path.join(parent, name),
          File.dir?(full) do
        %{path: full, name: name, created_at: dir_mtime(full)}
      end
      |> Enum.sort_by(& &1.name, :desc)
    else
      _ -> []
    end
  end

  defp dir_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> DateTime.from_unix!(mtime)
      _ -> nil
    end
  end

  @doc """
  Put a backup back in place, keeping the current folder as a fresh
  backup so the rollback is itself undoable.
  """
  def rollback(game, backup_path) do
    path = RenPy.game_path(game)

    with :ok <- check_owned_backup(game, backup_path),
         :ok <- check_target(path) do
      current_backup = Overwrite.backup_path(path)

      with :ok <- Overwrite.rename(path, current_backup, :backup_failed) do
        case File.rename(backup_path, path) do
          :ok ->
            {:ok, %{restored_from: backup_path, backup: current_backup}}

          {:error, reason} ->
            File.rename(current_backup, path)
            {:error, :swap_failed, %{reason: reason}}
        end
      end
    end
  end

  @doc "Delete a backup folder the user no longer wants."
  def discard(game, backup_path) do
    with :ok <- check_owned_backup(game, backup_path) do
      case File.rm_rf(backup_path) do
        {:ok, _} -> :ok
        {:error, reason, _} -> {:error, :discard_failed, %{reason: reason}}
      end
    end
  end

  # The path arrives from the interface, so it is checked against the
  # backups this game actually has rather than trusted.
  defp check_owned_backup(game, backup_path) do
    if Enum.any?(list_backups(game), &(&1.path == backup_path)) do
      :ok
    else
      {:error, :unknown_backup, %{path: backup_path}}
    end
  end

  defp drive({:ok, value}, _op), do: {:ok, value}
  defp drive(:ok, _op), do: :ok
  defp drive({:error, reason}, op), do: {:error, :drive, %{op: op, reason: reason}}
end
