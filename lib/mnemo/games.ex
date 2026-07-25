defmodule Mnemo.Games do
  @moduledoc """
  Enrolled games and their local persisted record.

  Live sync state belongs to `Mnemo.Game.Server`; this module only touches
  the database.
  """

  import Ecto.Query

  alias Mnemo.Games.Game
  alias Mnemo.Repo

  def list do
    Repo.all(from g in Game, order_by: [asc: g.name, asc: g.save_directory])
  end

  def list_enabled do
    Repo.all(from g in Game, where: g.enabled == true)
  end

  def get!(id), do: Repo.get!(Game, id)
  def get(id), do: Repo.get(Game, id)

  def get_by_directory(save_directory, install_root) do
    Repo.get_by(Game, save_directory: save_directory, install_root: install_root)
  end

  def enroll(attrs) do
    %Game{}
    |> Game.changeset(attrs)
    |> Repo.insert()
  end

  def update_game(%Game{} = game, attrs) do
    game
    |> Game.changeset(attrs)
    |> Repo.update()
  end

  def set_remote_folder(%Game{} = game, folder_id) do
    game
    |> Ecto.Changeset.change(remote_folder_id: folder_id)
    |> Repo.update()
  end

  def set_last_generation_seen(%Game{} = game, number) when is_integer(number) do
    game
    |> Ecto.Changeset.change(last_generation_seen: number)
    |> Repo.update()
  end
end
