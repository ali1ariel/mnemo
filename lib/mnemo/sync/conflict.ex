defmodule Mnemo.Sync.Conflict do
  @moduledoc """
  Resolving a diverged lineage.

  Both resolutions are lossless, and that falls out of manifests being
  append-only rather than from any care taken here: the remote generation
  that caused the conflict is never deleted, and the local files are
  published as a generation of their own before anything overwrites them.
  The choice is therefore only about which side sits on disk right now,
  not about which side survives.

    * `:keep_local` — adopt the remote lineage and publish what is on this
      machine on top of it. The files never move.
    * `:keep_remote` — same adoption, then restore the remote head, which
      saves the local files as a generation first.

  Saves are serialized pickle data inside a zip and never merge, so there
  is no third automatic option.

  `:fork` conflicts — two devices that published the *same* generation
  number — are not handled here. Those need a screen that shows both
  competing manifests, since the number alone no longer identifies one.
  """

  alias Mnemo.Drive.{Backend, Remote}
  alias Mnemo.{Games, RenPy, Settings}
  alias Mnemo.Sync.{Engine, Restore}

  @doc """
  What each side holds, for a choice made with eyes open rather than over
  two black boxes.
  """
  def sides(game) do
    with {:ok, ctx} <- context(game),
         {:ok, numbers} <-
           drive(
             Remote.list_generation_numbers(ctx.backend, ctx.remote.generations_id),
             :list_generations
           ),
         head when head > 0 <- Enum.max(numbers, fn -> 0 end),
         {:ok, manifest} <-
           drive(
             Remote.get_manifest(ctx.backend, ctx.remote.generations_id, head),
             :get_manifest
           ),
         {:ok, local_files} <- local_files(game) do
      remote_files = manifest["files"] || []

      {:ok,
       %{
         local: %{
           generation: game.last_generation_seen,
           device_id: Settings.device_id(),
           files: local_files
         },
         remote: %{
           generation: head,
           device_id: manifest["device_id"],
           created_at: manifest["created_at"],
           files: remote_files
         },
         diverging: diverging(local_files, remote_files),
         forked?: numbers != Enum.uniq(numbers)
       }}
    else
      0 -> {:error, :no_remote_history, %{}}
      error -> error
    end
  end

  @doc """
  Slot names that differ between the two sides, so the interface can name
  what is actually at stake instead of counting files.
  """
  def diverging(local_files, remote_files) do
    local = Map.new(local_files, &{&1["rel_path"], &1["sha256"]})
    remote = Map.new(remote_files, &{&1["rel_path"], &1["sha256"]})

    for path <- Enum.sort(Enum.uniq(Map.keys(local) ++ Map.keys(remote))),
        local[path] != remote[path] do
      %{
        rel_path: path,
        state:
          cond do
            local[path] == nil -> :only_remote
            remote[path] == nil -> :only_local
            true -> :changed
          end
      }
    end
  end

  @doc """
  Apply a resolution.

  `:keep_remote` overwrites the save folder, so it carries the same
  guards as any restore — the caller must confirm the game is closed.
  """
  def resolve(game, choice, opts \\ [], notify \\ fn _phase -> :ok end)

  def resolve(game, :keep_local, _opts, notify) do
    with {:ok, game} <- adopt_remote_lineage(game) do
      case Engine.run(game, notify) do
        {:ok, :no_changes} ->
          # Both sides held the same bytes; the divergence was only in the
          # numbering, and adopting the lineage already settled it.
          {:ok, %{resolution: :keep_local, result: :no_changes}}

        {:ok, summary} ->
          {:ok, Map.merge(summary, %{resolution: :keep_local})}

        error ->
          error
      end
    end
  end

  def resolve(game, :keep_remote, opts, notify) do
    with :ok <- Restore.precheck(game, opts),
         {:ok, game} <- adopt_remote_lineage(game),
         {:ok, head} <- remote_head(game),
         {:ok, summary} <- Restore.run(game, head, opts, notify) do
      {:ok, Map.merge(summary, %{resolution: :keep_remote})}
    end
  end

  # Recording the remote head as "seen" is the whole resolution: it says
  # this device has now looked at what the other one wrote, which is
  # exactly what `last_generation_seen` means. Everything after it is an
  # ordinary sync or restore.
  defp adopt_remote_lineage(game) do
    with {:ok, head} <- remote_head(game) do
      case Games.set_last_generation_seen(game, head) do
        {:ok, game} -> {:ok, game}
        {:error, changeset} -> {:error, :persist_failed, %{errors: inspect(changeset.errors)}}
      end
    end
  end

  defp remote_head(game) do
    with {:ok, ctx} <- context(game),
         {:ok, numbers} <-
           drive(
             Remote.list_generation_numbers(ctx.backend, ctx.remote.generations_id),
             :list_generations
           ) do
      if numbers != Enum.uniq(numbers) do
        {:error, :conflict, %{reason: :fork, numbers: Enum.uniq(numbers -- Enum.uniq(numbers))}}
      else
        {:ok, Enum.max(numbers, fn -> 0 end)}
      end
    end
  end

  defp context(game) do
    backend = Backend.impl()

    with {:ok, layout} <- drive(Remote.ensure_layout(backend), :ensure_layout),
         {:ok, remote} <- drive(Remote.ensure_game(backend, layout.games_id, game), :ensure_game) do
      {:ok, %{backend: backend, remote: remote}}
    end
  end

  defp local_files(game) do
    path = RenPy.game_path(game)

    if path && File.dir?(path) do
      files =
        path
        |> RenPy.tracked_files(
          sync_autosaves: game.sync_autosaves,
          exclude_patterns: game.exclude_patterns || []
        )
        |> Enum.flat_map(fn {rel, slot} ->
          # A file that vanished between listing and reading is simply not
          # part of the comparison; this view is never a commit point.
          case File.read(Path.join(path, rel)) do
            {:ok, content} ->
              [
                %{
                  "rel_path" => rel,
                  "sha256" => Base.encode16(:crypto.hash(:sha256, content), case: :lower),
                  "size" => byte_size(content),
                  "slot" => RenPy.slot_to_map(slot)
                }
              ]

            {:error, _} ->
              []
          end
        end)

      {:ok, files}
    else
      {:error, :missing_folder, %{path: path}}
    end
  end

  defp drive({:ok, value}, _op), do: {:ok, value}
  defp drive({:error, reason}, op), do: {:error, :drive, %{op: op, reason: reason}}
end
