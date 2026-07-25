defmodule Mnemo.Game do
  @moduledoc """
  Facade over the per-game server processes. Live sync state lives in
  `Mnemo.Game.Server`; LiveViews observe it over PubSub via `subscribe/0`.
  """

  @topic "games"

  def subscribe, do: Phoenix.PubSub.subscribe(Mnemo.PubSub, @topic)

  def broadcast_status(game_id, status) do
    Phoenix.PubSub.broadcast(Mnemo.PubSub, @topic, {:game, game_id, status})
  end

  def ensure_started(game_id) do
    case DynamicSupervisor.start_child(Mnemo.Game.Supervisor, {Mnemo.Game.Server, game_id}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      :ignore -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def start_all do
    for game <- Mnemo.Games.list_enabled(), do: ensure_started(game.id)

    :ok
  end

  def status(game_id) do
    with {:ok, pid} <- ensure_started(game_id) do
      GenServer.call(pid, :status)
    end
  end

  def sync_now(game_id) do
    with {:ok, pid} <- ensure_started(game_id) do
      GenServer.call(pid, :sync_now)
    end
  end

  def stop(game_id) do
    case Registry.lookup(Mnemo.Game.Registry, game_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Mnemo.Game.Supervisor, pid)
      [] -> :ok
    end
  end
end
