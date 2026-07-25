defmodule Mnemo.Sync.Import do
  @moduledoc """
  Bring saves in from a zip the player already has.

  The archives people actually hold are backups they made by hand and
  Google Takeout exports, so nothing about their shape can be assumed:
  the saves may sit at the root or nested under a folder or two, and the
  export may carry `__MACOSX` noise alongside them. Only the file name
  matters — `Mnemo.RenPy.parse_slot/1` decides what is a save and what is
  not, and the directory structure is discarded.

  An import is additive unless told otherwise. A save in the folder but
  not in the archive is never removed under `:add_missing` or
  `:overwrite`: an archive is not a manifest and must not be read as
  "delete the rest".

  `:replace` is the exception, and exists for one situation — a game
  enrolled from a folder holding nothing but the reference save that
  rule 2 requires. There the folder is not history worth keeping, the
  archive is, and clearing first is what stops a stale slot from
  outliving the import. It removes exactly the files the safety
  generation recorded, so everything it deletes is recoverable.

  Beyond that it follows `Mnemo.Sync.Overwrite` like a restore does — the
  current state is published as a generation, the new folder is built
  beside the old one, every `.save` is opened and checked before anything
  live is touched, and the swap is two renames.
  """

  alias Mnemo.{Paths, RenPy}
  alias Mnemo.Sync.{CaseCheck, Engine, Mirror, Overwrite, Restore}

  # A screenshot per entry is what makes the preview worth looking at,
  # but a folder of autosaves can hold hundreds. Past this many the
  # preview drops to names and sizes rather than holding tens of
  # megabytes of thumbnails in a LiveView's state.
  @preview_limit 100

  @doc """
  What an archive holds, without writing anything.

  Returns entries in archive order, each marked `present?` when the game
  folder already has a file of that name — which is what lets the
  interface say how many saves are new before the player commits.
  """
  def inspect_archive(archive_path, game) do
    path = RenPy.game_path(game)

    fold = fn member, _info, get_bin, acc ->
      name = member |> to_string() |> Path.basename()

      if noise?(to_string(member)) do
        acc
      else
        case RenPy.parse_slot(name) do
          :other -> %{acc | ignored: acc.ignored + 1}
          slot -> collect(acc, to_string(member), name, slot, get_bin, path)
        end
      end
    end

    case RenPy.fold_members(fold, %{entries: [], ignored: 0, duplicates: 0}, archive_path) do
      {:ok, acc} ->
        entries = Enum.reverse(acc.entries)
        {:ok, %{entries: entries, ignored: acc.ignored, duplicates: acc.duplicates}}

      {:error, reason} ->
        {:error, :unreadable_archive, %{reason: reason}}
    end
  end

  # Takeout and macOS zips carry resource forks and directory entries
  # next to the real files; `._1-1-LT1.save` parses as nothing useful but
  # counting it as ignored would misreport how much the archive holds.
  defp noise?(member) do
    String.starts_with?(member, "__MACOSX/") or String.ends_with?(member, "/")
  end

  defp collect(acc, member, name, slot, get_bin, game_path) do
    if Enum.any?(acc.entries, &(&1.name == name)) do
      # Same save filed under two folders inside the archive. The first
      # wins, because nothing in a zip says which copy is newer.
      %{acc | duplicates: acc.duplicates + 1}
    else
      bytes = get_bin.()

      entry = %{
        member: member,
        name: name,
        slot: slot,
        size: byte_size(bytes),
        save_name: save_name(slot, name, bytes),
        screenshot: screenshot(slot, name, bytes, length(acc.entries)),
        present?: game_path != nil and File.regular?(Path.join(game_path, name))
      }

      %{acc | entries: [entry | acc.entries]}
    end
  end

  defp save_name(:persistent, _name, _bytes), do: nil
  defp save_name(_slot, name, bytes), do: RenPy.save_name({name, bytes})

  defp screenshot(:persistent, _name, _bytes, _index), do: nil
  defp screenshot(_slot, _name, _bytes, index) when index >= @preview_limit, do: nil

  defp screenshot(_slot, name, bytes, _index) do
    case RenPy.extract_screenshot({name, bytes}) do
      {:ok, png} -> png
      {:error, _} -> nil
    end
  end

  @doc """
  What an import would do: which archive entries get written, which are
  left alone, and which files already in the folder go away.

  `mode` is `:add_missing` (the default), `:overwrite` or `:replace`.
  Computing the removals here rather than at staging time is deliberate —
  the interface shows the same list the swap acts on, so what the player
  agreed to and what happens cannot drift apart.
  """
  def plan(game, found, mode \\ :add_missing) do
    {write, skip} = Enum.split_with(found.entries, &writable?(&1, mode))
    %{write: write, skip: skip, remove: removals(game, write, mode), mode: mode}
  end

  defp writable?(_entry, :overwrite), do: true
  defp writable?(_entry, :replace), do: true
  defp writable?(entry, _add_missing), do: not entry.present?

  # Only tracked files, which is the same set a restore clears and the
  # same set the safety generation captured. Anything outside it — the
  # autosaves when they are switched off, Ren'Py's own `sync/` folder —
  # is not in any generation, so deleting it would not be undoable.
  defp removals(game, write, :replace) do
    provided = MapSet.new(write, & &1.name)

    case RenPy.game_path(game) do
      nil ->
        []

      path ->
        path
        |> RenPy.tracked_files(
          sync_autosaves: game.sync_autosaves,
          exclude_patterns: game.exclude_patterns || []
        )
        |> Enum.map(fn {rel, _slot} -> rel end)
        |> Enum.reject(&MapSet.member?(provided, &1))
    end
  end

  defp removals(_game, _write, _mode), do: []

  @doc """
  Put an archive's saves into the game folder.

  Options: `:mode`, plus the guards `Mnemo.Sync.Restore.precheck/2` takes
  (`:confirmed_closed`, `:force`) — an import overwrites the same folder a
  restore does, so it answers to the same rule about the game being
  closed. `publish: false` keeps the result off Drive.

  `discard_archive: true` deletes the archive once the work is over,
  whichever way it went. That is for callers that handed over an upload
  and will not be around to clean it up.
  """
  def run(game, archive_path, opts \\ [], notify \\ fn _phase -> :ok end) do
    do_run(game, archive_path, opts, notify)
  after
    if Keyword.get(opts, :discard_archive, false), do: File.rm(archive_path)
  end

  defp do_run(game, archive_path, opts, notify) do
    path = RenPy.game_path(game)
    mode = Keyword.get(opts, :mode, :add_missing)

    with :ok <- Restore.precheck(game, opts),
         {:ok, found} <- inspect_archive(archive_path, game),
         plan = plan(game, found, mode),
         :ok <- check_something_to_do(plan, found),
         :ok <- check_case(path, plan),
         :ok <- Paths.check_length(target_paths(path, plan)),
         {:ok, game, safety} <- Overwrite.safety_generation(game, opts, notify) do
      staging = Overwrite.staging_dir(path, "import")
      mirrors = Mirror.plan(game, path)

      try do
        notify.(:importing)

        with :ok <- stage(archive_path, path, staging, plan),
             {:ok, backup} <- swap(path, staging, notify) do
          finish(game, plan, safety, backup, opts, notify, Mirror.apply(mirrors, game, path))
        end
      after
        File.rm_rf(staging)
      end
    end
  end

  # The staging directory is the longest path an import builds, so it is
  # measured rather than the live folder.
  defp target_paths(nil, _plan), do: []

  defp target_paths(path, plan) do
    dir = Overwrite.staging_dir(path, "import")
    [dir | Enum.map(plan.write, &Path.join(dir, &1.name))]
  end

  defp check_something_to_do(%{write: []}, %{entries: []}),
    do: {:error, :no_saves_in_archive, %{}}

  defp check_something_to_do(%{write: []}, found),
    do: {:error, :nothing_to_import, %{already_present: length(found.entries)}}

  defp check_something_to_do(_plan, _found), do: :ok

  # What the folder ends up holding: everything the archive writes, plus
  # what was already there and is not being removed. Two of those folding
  # into one name on Windows would mean an archive entry quietly landing
  # on top of a save nobody agreed to replace.
  defp check_case(nil, _plan), do: :ok

  defp check_case(path, plan) do
    surviving =
      case File.ls(path) do
        {:ok, entries} -> entries -- plan.remove
        {:error, _} -> []
      end

    CaseCheck.check(path, surviving ++ Enum.map(plan.write, & &1.name))
  end

  ## Staging

  # Everything currently in the folder is carried over first, so files the
  # archive does not mention — and `:replace` did not list for removal —
  # survive untouched.
  defp stage(archive_path, path, staging, plan) do
    with :ok <- copy_current(path, staging),
         :ok <- remove(staging, plan.remove),
         :ok <- extract(archive_path, staging, plan.write),
         do: validate(staging, plan.write)
  end

  defp remove(staging, names) do
    Enum.reduce_while(names, :ok, fn name, :ok ->
      case File.rm(Path.join(staging, name)) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, :staging_failed, %{reason: reason, file: name}}}
      end
    end)
  end

  defp copy_current(path, staging) do
    File.rm_rf(staging)

    case File.cp_r(path, staging) do
      {:ok, _} -> :ok
      {:error, reason, file} -> {:error, :staging_failed, %{reason: reason, file: file}}
    end
  end

  defp extract(archive_path, staging, entries) do
    wanted = Map.new(entries, &{&1.member, &1.name})

    write = fn member, _info, get_bin, failures ->
      case Map.fetch(wanted, to_string(member)) do
        {:ok, name} ->
          case File.write(Path.join(staging, name), get_bin.()) do
            :ok -> failures
            {:error, reason} -> [%{file: name, reason: reason} | failures]
          end

        :error ->
          failures
      end
    end

    case RenPy.fold_members(write, [], archive_path) do
      {:ok, []} -> :ok
      {:ok, failures} -> {:error, :staging_failed, %{failures: failures}}
      {:error, reason} -> {:error, :unreadable_archive, %{reason: reason}}
    end
  end

  # Rule 4 applies to anything arriving from outside, and an archive that
  # sat in cloud storage for a year is exactly the kind of thing that
  # arrives truncated. A save that will not open never reaches the folder.
  defp validate(staging, entries) do
    entries
    |> Enum.filter(&(&1.slot != :persistent))
    |> Enum.reduce_while(:ok, fn entry, :ok ->
      case RenPy.validate_save(Path.join(staging, entry.name)) do
        :ok -> {:cont, :ok}
        {:error, detail} -> {:halt, {:error, :invalid_save, detail}}
      end
    end)
  end

  defp swap(path, staging, notify) do
    notify.(:swapping)
    Overwrite.swap(path, staging)
  end

  ## Commit

  defp finish(game, plan, safety, backup, opts, notify, mirrors) do
    summary = %{
      mirrors: mirrors,
      imported: length(plan.write),
      skipped: length(plan.skip),
      removed: length(plan.remove),
      mode: plan.mode,
      safety: safety,
      backup: Overwrite.settle_backup(backup, safety)
    }

    if Keyword.get(opts, :publish, true) do
      {:ok, Map.merge(summary, publish(game, notify))}
    else
      {:ok, summary}
    end
  end

  # The files are already on disk at this point, so a failed upload is
  # reported alongside the import rather than turning it into an error —
  # the next sync will pick them up.
  defp publish(game, notify) do
    case Engine.run(game, notify) do
      {:ok, %{generation: number}} -> %{generation: number}
      {:ok, :no_changes} -> %{generation: game.last_generation_seen}
      {:error, tag, detail} -> %{publish_error: %{tag: tag, detail: detail}}
    end
  end
end
