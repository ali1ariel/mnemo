defmodule Mnemo.Sync.Engine do
  @moduledoc """
  One sync cycle: snapshot → validate → hash → dedupe → upload → manifest.

  The manifest write is the commit point — it happens only after every
  blob upload succeeded, and the local database checkpoint happens only
  after the manifest is in place. Errors are structured
  (`{:error, tag, detail}`), never strings: language is a presentation
  concern and structured detail feeds retry policy.
  """

  alias Mnemo.Drive.{Backend, Remote}
  alias Mnemo.{Games, RenPy, Settings, Sync}

  @upload_concurrency 3

  def run(game, notify \\ fn _phase -> :ok end) do
    path = RenPy.game_path(game)

    cond do
      path == nil ->
        {:error, :no_root, %{install_root: game.install_root}}

      not File.dir?(path) ->
        {:error, :missing_folder, %{path: path}}

      true ->
        snapshot_dir = snapshot_dir(game)

        try do
          run_cycle(game, path, snapshot_dir, notify)
        after
          File.rm_rf(snapshot_dir)
        end
    end
  end

  defp run_cycle(game, path, snapshot_dir, notify) do
    backend = Backend.impl()
    notify.(:snapshotting)

    with {:ok, files} <- take_snapshot(game, path, snapshot_dir),
         :ok <- validate_snapshot(snapshot_dir, files),
         {:ok, entries} <- hash_snapshot(snapshot_dir, files),
         {:ok, layout} <- drive(Remote.ensure_layout(backend), :ensure_layout),
         {:ok, remote} <- drive(Remote.ensure_game(backend, layout.games_id, game), :ensure_game),
         {:ok, game} <- persist_remote_folder(game, remote),
         {:ok, numbers} <-
           drive(
             Remote.list_generation_numbers(backend, remote.generations_id),
             :list_generations
           ),
         :ok <- check_lineage(game, numbers),
         {:ok, plan} <- plan(backend, game, remote, entries) do
      case plan do
        :no_changes ->
          {:ok, :no_changes}

        {:advance, number, parent} ->
          notify.(:uploading)
          advance(backend, game, remote, snapshot_dir, entries, number, parent)
      end
    end
  end

  defp advance(backend, game, remote, snapshot_dir, entries, number, parent) do
    manifest = build_manifest(number, parent, entries)

    with {:ok, stats} <- upload_blobs(backend, remote.blobs_id, snapshot_dir, entries),
         {:ok, meta} <-
           drive(
             Remote.put_manifest(backend, remote.generations_id, number, manifest),
             :put_manifest
           ),
         :ok <- check_write_race(backend, remote.generations_id, number) do
      checkpoint(game, number, parent, entries, meta)
      {:ok, %{generation: number, uploaded: stats.uploaded, skipped: stats.skipped}}
    end
  end

  ## Snapshot

  defp snapshot_dir(game) do
    Path.join(
      System.tmp_dir!(),
      "mnemo-snap-#{game.id}-#{System.unique_integer([:positive])}"
    )
  end

  defp take_snapshot(game, path, snapshot_dir) do
    tracked =
      RenPy.tracked_files(path,
        sync_autosaves: game.sync_autosaves,
        exclude_patterns: game.exclude_patterns || []
      )

    if tracked == [] do
      # A reference save is required on every machine: launching the game
      # once and quitting creates the folder and writes `persistent`.
      {:error, :no_saves, %{path: path}}
    else
      File.mkdir_p!(snapshot_dir)

      Enum.reduce_while(tracked, {:ok, []}, fn {rel, slot}, {:ok, acc} ->
        case File.cp(Path.join(path, rel), Path.join(snapshot_dir, rel)) do
          :ok -> {:cont, {:ok, [{rel, slot} | acc]}}
          {:error, reason} -> {:halt, {:error, :snapshot_failed, %{file: rel, reason: reason}}}
        end
      end)
    end
  end

  defp validate_snapshot(snapshot_dir, files) do
    files
    |> Enum.filter(fn {rel, _slot} -> String.ends_with?(rel, ".save") end)
    |> Enum.reduce_while(:ok, fn {rel, _slot}, :ok ->
      case RenPy.validate_save(Path.join(snapshot_dir, rel)) do
        :ok -> {:cont, :ok}
        {:error, detail} -> {:halt, {:error, :invalid_save, detail}}
      end
    end)
  end

  defp hash_snapshot(snapshot_dir, files) do
    files
    |> Enum.sort_by(fn {rel, _slot} -> rel end)
    |> Enum.reduce_while({:ok, []}, fn {rel, slot}, {:ok, acc} ->
      case File.read(Path.join(snapshot_dir, rel)) do
        {:ok, content} ->
          entry = %{
            "rel_path" => rel,
            "sha256" => Base.encode16(:crypto.hash(:sha256, content), case: :lower),
            "size" => byte_size(content),
            "slot" => RenPy.slot_to_map(slot)
          }

          {:cont, {:ok, [entry | acc]}}

        {:error, reason} ->
          {:halt, {:error, :hash_failed, %{file: rel, reason: reason}}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  ## Lineage

  defp check_lineage(game, numbers) do
    duplicated = numbers -- Enum.uniq(numbers)
    remote_head = Enum.max(numbers, fn -> 0 end)
    last_seen = game.last_generation_seen

    cond do
      duplicated != [] ->
        {:error, :conflict, %{reason: :fork, numbers: Enum.uniq(duplicated)}}

      remote_head > last_seen and last_seen == 0 ->
        # Enrollment over an existing remote and a conflict are the same
        # thing: local state with unknown lineage versus a remote head.
        {:error, :conflict, %{reason: :foreign_lineage, remote_head: remote_head}}

      remote_head > last_seen ->
        {:error, :conflict,
         %{reason: :remote_ahead, remote_head: remote_head, last_seen: last_seen}}

      remote_head < last_seen ->
        {:error, :conflict,
         %{reason: :remote_behind, remote_head: remote_head, last_seen: last_seen}}

      true ->
        :ok
    end
  end

  defp plan(backend, game, remote, entries) do
    head = game.last_generation_seen

    if head == 0 do
      {:ok, {:advance, 1, 0}}
    else
      with {:ok, previous_files} <- previous_manifest_files(backend, game, remote, head) do
        if file_set(previous_files) == file_set(entries) do
          {:ok, :no_changes}
        else
          {:ok, {:advance, head + 1, head}}
        end
      end
    end
  end

  defp previous_manifest_files(backend, game, remote, head) do
    case Sync.get_generation(game.id, head) do
      %{manifest: files} when is_list(files) ->
        {:ok, files}

      nil ->
        # Local database was wiped; the remote still has the manifest.
        with {:ok, manifest} <-
               drive(Remote.get_manifest(backend, remote.generations_id, head), :get_manifest) do
          {:ok, manifest["files"] || []}
        end
    end
  end

  defp file_set(files) do
    MapSet.new(files, fn file -> {file["rel_path"], file["sha256"]} end)
  end

  ## Upload

  defp upload_blobs(backend, blobs_id, snapshot_dir, entries) do
    case remote_blob_names(backend, blobs_id) do
      {:ok, present} ->
        entries
        |> Enum.uniq_by(& &1["sha256"])
        |> Enum.reject(&MapSet.member?(present, &1["sha256"]))
        |> push(backend, blobs_id, snapshot_dir, length(entries))

      {:error, reason} ->
        {:error, :drive, %{op: :list_blobs, reason: reason}}
    end
  end

  # The local `blobs` table is a cache, never the authority on what the
  # remote holds: it survives the Drive folder being deleted, the account
  # being switched, and `mix mnemo.reset --remote`. Trusting it would let
  # a cycle skip uploads and publish a manifest pointing at bytes that are
  # not there — a sync that reports success over a hollow backup, which
  # only surfaces when someone tries to restore. Listing the folder once
  # per cycle is one call and removes the whole class of failure.
  defp remote_blob_names(backend, blobs_id) do
    with {:ok, children} <- backend.list_children(blobs_id) do
      {:ok, MapSet.new(children, & &1.name)}
    end
  end

  defp push(unknown, backend, blobs_id, snapshot_dir, total) do
    results =
      Task.Supervisor.async_stream_nolink(
        Mnemo.TaskSupervisor,
        unknown,
        fn entry -> upload_one(backend, blobs_id, snapshot_dir, entry) end,
        max_concurrency: @upload_concurrency,
        timeout: 300_000,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.to_list()

    failures =
      Enum.flat_map(results, fn
        {:ok, {:ok, _outcome}} -> []
        {:ok, {:error, detail}} -> [detail]
        {:exit, reason} -> [%{reason: {:exit, reason}}]
      end)

    if failures == [] do
      uploaded = Enum.count(results, &(&1 == {:ok, {:ok, :uploaded}}))
      {:ok, %{uploaded: uploaded, skipped: total - uploaded}}
    else
      {:error, :upload_failed, %{failures: failures}}
    end
  end

  defp upload_one(backend, blobs_id, snapshot_dir, entry) do
    content = File.read!(Path.join(snapshot_dir, entry["rel_path"]))

    case Remote.upload_blob(backend, blobs_id, entry["sha256"], content) do
      {:ok, meta, outcome} ->
        Sync.record_blob(entry["sha256"], entry["size"], meta.id)
        {:ok, outcome}

      {:error, reason} ->
        {:error, %{file: entry["rel_path"], sha256: entry["sha256"], reason: reason}}
    end
  end

  ## Commit

  defp build_manifest(number, parent, entries) do
    %{
      "number" => number,
      "parent_number" => parent,
      "device_id" => Settings.device_id(),
      # Decoration only — generation numbers order, timestamps never do.
      "created_at" => DateTime.to_iso8601(DateTime.utc_now(:second)),
      "files" => entries
    }
  end

  # Drive has no compare-and-swap; re-listing after the write detects the
  # race where another device published the same number concurrently.
  defp check_write_race(backend, generations_id, number) do
    case Remote.list_generation_numbers(backend, generations_id) do
      {:ok, numbers} ->
        if Enum.count(numbers, &(&1 == number)) > 1 do
          {:error, :conflict, %{reason: :fork, numbers: [number]}}
        else
          :ok
        end

      {:error, reason} ->
        {:error, :drive, %{op: :check_write_race, reason: reason}}
    end
  end

  defp checkpoint(game, number, parent, entries, manifest_meta) do
    Sync.record_generation(game.id, %{
      number: number,
      parent_number: parent,
      device_id: Settings.device_id(),
      validated: true,
      byte_size: entries |> Enum.map(& &1["size"]) |> Enum.sum(),
      remote_manifest_id: manifest_meta.id,
      manifest: entries
    })

    {:ok, _game} = Games.set_last_generation_seen(game, number)
    :ok
  end

  defp persist_remote_folder(game, remote) do
    if game.remote_folder_id == remote.folder_id do
      {:ok, game}
    else
      case Games.set_remote_folder(game, remote.folder_id) do
        {:ok, game} -> {:ok, game}
        {:error, changeset} -> {:error, :persist_failed, %{errors: inspect(changeset.errors)}}
      end
    end
  end

  defp drive({:ok, value}, _op), do: {:ok, value}
  defp drive(:ok, _op), do: :ok
  defp drive({:error, reason}, op), do: {:error, :drive, %{op: op, reason: reason}}
end
