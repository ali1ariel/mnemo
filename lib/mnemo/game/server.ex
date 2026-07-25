defmodule Mnemo.Game.Server do
  @moduledoc """
  Per-game process holding live sync state.

  States: `:idle → :snapshotting → :uploading → :ok | :conflict | :error`.
  (`:dirty` and `:settling` arrive with the watcher in v1.) The cycle
  itself runs in a supervised task so this process stays responsive to
  status queries; the database is only touched at checkpoints, inside the
  engine.
  """

  use GenServer, restart: :transient

  alias Mnemo.{Games, Sync}
  alias Mnemo.Sync.Engine

  def start_link(game_id) do
    GenServer.start_link(__MODULE__, game_id, name: via(game_id))
  end

  defp via(game_id), do: {:via, Registry, {Mnemo.Game.Registry, game_id}}

  @impl true
  def init(game_id) do
    case Games.get(game_id) do
      nil ->
        :ignore

      game ->
        head = Sync.head_generation(game.id)

        {:ok,
         %{
           game: game,
           status: :idle,
           detail: %{},
           task_ref: nil,
           last_synced_at: head && head.inserted_at
         }}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  def handle_call(:sync_now, _from, %{task_ref: ref} = state) when ref != nil do
    {:reply, {:error, :busy}, state}
  end

  def handle_call(:sync_now, _from, state) do
    server = self()
    game = state.game

    task =
      Task.Supervisor.async_nolink(Mnemo.TaskSupervisor, fn ->
        Engine.run(game, fn phase -> send(server, {:sync_phase, phase}) end)
      end)

    state = %{state | task_ref: task.ref, status: :snapshotting, detail: %{}}
    publish(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:sync_phase, phase}, state) do
    state = %{state | status: phase}
    publish(state)
    {:noreply, state}
  end

  def handle_info({ref, result}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    game = Games.get(state.game.id) || state.game
    state = %{state | task_ref: nil, game: game}

    state =
      case result do
        {:ok, :no_changes} ->
          %{
            state
            | status: :ok,
              detail: %{result: :no_changes},
              last_synced_at: DateTime.utc_now(:second)
          }

        {:ok, %{generation: _} = summary} ->
          %{state | status: :ok, detail: summary, last_synced_at: DateTime.utc_now(:second)}

        {:error, :conflict, detail} ->
          %{state | status: :conflict, detail: detail}

        {:error, tag, detail} ->
          %{state | status: :error, detail: Map.put(detail, :tag, tag)}
      end

    publish(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    state = %{
      state
      | task_ref: nil,
        status: :error,
        detail: %{tag: :crashed, reason: inspect(reason)}
    }

    publish(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp public_status(state) do
    %{
      game_id: state.game.id,
      status: state.status,
      detail: state.detail,
      syncing?: state.task_ref != nil,
      last_synced_at: state.last_synced_at,
      last_generation: state.game.last_generation_seen
    }
  end

  defp publish(state), do: Mnemo.Game.broadcast_status(state.game.id, public_status(state))
end
