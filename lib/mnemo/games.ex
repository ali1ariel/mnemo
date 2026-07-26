defmodule Mnemo.Games do
  @moduledoc """
  Enrolled games and their local persisted record.

  Live sync state belongs to `Mnemo.Game.Server`; this module only touches
  the database.
  """

  import Ecto.Query

  alias Mnemo.Games.Game
  alias Mnemo.{RenPy, Repo, Sync}

  def list do
    Repo.all(from g in Game, order_by: [asc: g.name, asc: g.save_directory])
  end

  def list_enabled do
    Repo.all(from g in Game, where: g.enabled == true)
  end

  def get!(id), do: Repo.get!(Game, id)
  def get(id), do: Repo.get(Game, id)

  @doc """
  The name this game is filed under in the remote, and the key another
  machine matches itself against.

  Games in the OS Ren'Py root are identified by their `save_directory`,
  which `config.save_directory` makes unique. A game-local save folder is
  always literally `saves`, so every portable install would land in the
  same remote folder; those are keyed by their install directory name
  instead, which is what Steam and itch.io keep stable across machines.
  """
  def remote_key(%Game{save_directory: "saves", install_root: install_root})
      when is_binary(install_root) do
    install_root |> Path.dirname() |> Path.basename()
  end

  def remote_key(%Game{save_directory: save_directory}), do: save_directory

  def get_by_directory(save_directory, install_root) do
    Repo.get_by(Game, save_directory: save_directory, install_root: install_root)
  end

  def enroll(attrs) do
    %Game{}
    |> Game.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Enrolled games that are really one game, grouped. Groups of one are
  dropped — only a split is worth saying anything about.

  Ren'Py writes a game's saves to the user savedir *and* to
  `<gamedir>/saves`, and enrolling both folders gives one game two
  lineages: two remote folders, two histories, and two generation
  numbers that disagree about the same saves. The scan collapses the
  folders before they are offered, but a game enrolled while that
  collapse still needed a matching `.save` to work is already split, and
  no later scan undoes it.
  """
  def mirror_groups(games \\ list()) do
    games
    |> Enum.reduce([], fn game, groups ->
      case Enum.find_index(groups, &mirrors?(&1, game)) do
        nil -> groups ++ [[game]]
        index -> List.update_at(groups, index, &(&1 ++ [game]))
      end
    end)
    |> Enum.filter(&match?([_, _ | _], &1))
  end

  defp mirrors?(group, game) do
    locations = locations(game)

    Enum.any?(group, fn other ->
      Enum.any?(locations(other), fn a -> Enum.any?(locations, &RenPy.same_game?(a, &1)) end)
    end)
  end

  defp locations(game) do
    case RenPy.game_path(game) do
      nil -> RenPy.mirror_paths(game)
      path -> [path | RenPy.other_locations(game)]
    end
  end

  @doc """
  Forget a game locally.

  The saves stay on disk and everything already published stays in
  Drive — this only stops mnemo from tracking the folder, which is what
  makes it the way out of a game enrolled twice: the lineage that stays
  covers the same folders, so nothing that was captured stops being
  reachable.
  """
  def delete(%Game{} = game) do
    Repo.transaction(fn ->
      Sync.delete_generations(game.id)
      Repo.delete!(game)
    end)
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
