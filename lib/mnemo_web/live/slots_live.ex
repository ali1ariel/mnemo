defmodule MnemoWeb.SlotsLive do
  @moduledoc """
  The slot grid for one game, the way Ren'Py renders it: regular saves
  grouped by page, autosaves and quicksaves in their own sections.
  """

  use MnemoWeb, :live_view

  import MnemoWeb.GameComponents

  alias Mnemo.{Drive, Game, Games, RenPy}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    with {:ok, _uuid} <- Ecto.UUID.cast(id),
         %{} = game <- Games.get(id) do
      if connected?(socket) do
        Game.subscribe()
        Drive.subscribe()
      end

      {:ok,
       socket
       |> assign(page_title: game.name || game.save_directory)
       |> assign(game: game)
       |> assign(path: RenPy.game_path(game))
       |> assign(drive: Drive.status())
       |> assign(status: game_status(game))
       |> assign_saves()}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Game not found."))
         |> push_navigate(to: ~p"/")}
    end
  end

  defp game_status(game) do
    case Game.status(game.id) do
      %{} = status ->
        status

      {:error, _} ->
        %{
          game_id: game.id,
          status: :idle,
          detail: %{},
          syncing?: false,
          last_synced_at: nil,
          last_generation: game.last_generation_seen
        }
    end
  end

  defp assign_saves(socket) do
    game = socket.assigns.game

    saves =
      case socket.assigns.path do
        nil -> []
        path -> RenPy.list_saves(path)
      end

    saves = Enum.map(saves, &Map.put(&1, :src, slot_src(game, &1)))
    assign(socket, :groups, group_saves(saves))
  end

  defp slot_src(_game, %{screenshot?: false}), do: nil

  defp slot_src(game, save) do
    ~p"/covers/#{game.id}/#{save.file}?v=#{DateTime.to_unix(save.mtime)}"
  end

  @impl true
  def handle_info({:game, game_id, status}, %{assigns: %{game: %{id: game_id}}} = socket) do
    {:noreply, assign(socket, :status, status)}
  end

  def handle_info({:game, _other_game, _status}, socket), do: {:noreply, socket}

  def handle_info({:drive, status}, socket) do
    {:noreply, assign(socket, :drive, status)}
  end

  @impl true
  def handle_event("sync", _params, socket) do
    case Game.sync_now(socket.assigns.game.id) do
      :ok ->
        {:noreply, socket}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, gettext("A sync is already running."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not start the sync."))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex items-start justify-between gap-4">
        <div class="space-y-1">
          <div class="flex items-center gap-3">
            <h1 class="text-lg font-semibold">{@game.name || @game.save_directory}</h1>
            <.status_badge status={@status} />
          </div>
          <p class="text-xs opacity-50 font-mono">{@path || @game.save_directory}</p>
          <p class="text-sm opacity-70">
            {gettext("Generation %{number}", number: @status.last_generation)} · {gettext(
              "last sync: %{time}",
              time: relative_time(@status.last_synced_at)
            )}
          </p>
          <p :if={message = detail_message(@status)} class="text-sm">{message}</p>
        </div>
        <.button
          id="sync-now"
          phx-click="sync"
          disabled={@status.syncing? or @drive.state != :connected}
        >
          <.icon
            name="hero-arrow-path"
            class={["size-4", @status.syncing? && "motion-safe:animate-spin"]}
          /> {gettext("Sync now")}
        </.button>
      </div>

      <div :if={@groups.empty?} id="no-saves" class="card bg-base-200 p-10 text-center space-y-2">
        <h2 class="font-semibold">
          {gettext("No saves found. Launch the game once, quit, and try again.")}
        </h2>
      </div>

      <.saves_browser :if={not @groups.empty?} groups={@groups} />
    </Layouts.app>
    """
  end
end
