defmodule Mnemo.Reset do
  @moduledoc """
  Development helper that puts mnemo back to a clean slate.

  Destructive on purpose: the remote wipe permanently deletes the whole
  `/mnemo` folder in Drive. Nothing here is wired to the interface — it
  is reached through `mix mnemo.reset` or from IEx.
  """

  import Ecto.Query

  alias Mnemo.Drive.{Backend, Remote}
  alias Mnemo.Settings.Setting
  alias Mnemo.Sync.{Blob, Generation}
  alias Mnemo.{Games, Repo}

  # Credentials survive a reset: re-pasting them on every iteration is
  # exactly the friction this task exists to remove.
  @kept_settings ~w(google_client_id google_client_secret locale device_id)

  @doc """
  Drops every game, generation and blob recorded locally.

  Stops the running `Game.Server` processes first so they do not keep
  writing against rows that no longer exist. Pass `new_device: true` to
  also forget this machine's `device_id`, which makes the next sync look
  like a brand new install.
  """
  def local(opts \\ []) do
    for game <- Games.list(), do: Mnemo.Game.stop(game.id)

    {generations, _} = Repo.delete_all(Generation)
    {blobs, _} = Repo.delete_all(Blob)
    {games, _} = Repo.delete_all(Games.Game)

    kept = if opts[:new_device], do: @kept_settings -- ["device_id"], else: @kept_settings
    {settings, _} = Repo.delete_all(from s in Setting, where: s.key not in ^kept)

    %{games: games, generations: generations, blobs: blobs, settings: settings}
  end

  @doc """
  Permanently deletes the `/mnemo` folder in Drive, with everything under
  it. Returns `{:ok, :deleted}` or `{:ok, :absent}`.
  """
  def remote do
    backend = Backend.impl()

    case backend.find_child("root", Remote.root_name()) do
      {:ok, nil} -> {:ok, :absent}
      {:ok, meta} -> with :ok <- backend.delete(meta.id), do: {:ok, :deleted}
      error -> error
    end
  end

  @doc "Local wipe plus remote wipe."
  def all(opts \\ []) do
    with {:ok, remote} <- remote() do
      {:ok, %{local: local(opts), remote: remote}}
    end
  end
end
