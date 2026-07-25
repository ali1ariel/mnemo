defmodule Mnemo.Sync do
  @moduledoc """
  Persisted sync record: generations and the blob index.

  The blob index is what makes deduplication work — before uploading a file
  the engine looks its hash up here.
  """

  import Ecto.Query

  alias Mnemo.Repo
  alias Mnemo.Sync.{Blob, Generation}

  def get_blob(sha256), do: Repo.get(Blob, sha256)

  def record_blob(sha256, size, remote_file_id) do
    Repo.insert!(
      %Blob{
        sha256: sha256,
        size: size,
        remote_file_id: remote_file_id,
        uploaded_at: DateTime.utc_now(:second)
      },
      on_conflict: {:replace, [:remote_file_id, :uploaded_at]},
      conflict_target: :sha256
    )
  end

  def record_generation(game_id, attrs) do
    Repo.insert!(%Generation{
      game_id: game_id,
      number: attrs.number,
      parent_number: attrs.parent_number,
      device_id: attrs.device_id,
      validated: attrs.validated,
      byte_size: attrs.byte_size,
      remote_manifest_id: attrs[:remote_manifest_id],
      manifest: attrs.manifest
    })
  end

  def head_generation(game_id) do
    Repo.one(
      from g in Generation,
        where: g.game_id == ^game_id,
        order_by: [desc: g.number],
        limit: 1
    )
  end

  def get_generation(game_id, number) do
    Repo.one(
      from g in Generation,
        where: g.game_id == ^game_id and g.number == ^number,
        order_by: [desc: g.inserted_at],
        limit: 1
    )
  end

  def list_generations(game_id) do
    Repo.all(from g in Generation, where: g.game_id == ^game_id, order_by: [desc: g.number])
  end
end
