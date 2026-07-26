defmodule MnemoWeb.LibraryLive do
  use MnemoWeb, :live_view

  import MnemoWeb.DriveComponents
  import MnemoWeb.GameComponents

  alias Mnemo.{Drive, Game, Games}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Game.subscribe()
      Drive.subscribe()
    end

    games = Games.list()

    statuses =
      Map.new(games, fn game ->
        status =
          case Game.status(game.id) do
            %{} = status -> status
            {:error, _} -> offline_status(game)
          end

        {game.id, status}
      end)

    {:ok,
     socket
     |> assign(page_title: gettext("Library"))
     |> assign(drive: Drive.status())
     |> assign(games: games)
     |> assign(mirror_groups: Games.mirror_groups(games))
     |> assign(statuses: statuses)}
  end

  defp offline_status(game) do
    %{
      game_id: game.id,
      status: :idle,
      detail: %{},
      syncing?: false,
      last_synced_at: nil,
      last_generation: game.last_generation_seen
    }
  end

  @impl true
  def handle_info({:game, game_id, status}, socket) do
    if Map.has_key?(socket.assigns.statuses, game_id) do
      {:noreply, assign(socket, :statuses, Map.put(socket.assigns.statuses, game_id, status))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:drive, status}, socket) do
    {:noreply, assign(socket, :drive, status)}
  end

  @impl true
  def handle_event("sync", %{"id" => id}, socket) do
    case Game.sync_now(id) do
      :ok ->
        {:noreply, socket}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, gettext("A sync is already running."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not start the sync."))}
    end
  end

  def handle_event("forget", %{"id" => id}, socket) do
    case Games.get(id) do
      nil ->
        {:noreply, socket}

      game ->
        Game.stop(game.id)
        {:ok, _} = Games.delete(game)

        {:noreply,
         socket
         |> put_flash(:info, gettext("%{name} is no longer tracked twice.", name: game.name))
         |> push_navigate(to: ~p"/")}
    end
  end

  def handle_event("connect_drive", _params, socket) do
    case Drive.connect() do
      :ok ->
        {:noreply, socket}

      {:error, :not_configured} ->
        {:noreply, put_flash(socket, :error, gettext("Google OAuth client is not configured."))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.drive_banner drive={@drive} settings_link />

      <.mirror_notice
        :for={{group, index} <- Enum.with_index(@mirror_groups)}
        group={group}
        index={index}
      />

      <div :if={@games == []} id="empty-library" class="card bg-base-200 p-10 text-center space-y-4">
        <h2 class="text-lg font-semibold">{gettext("No games enrolled yet")}</h2>
        <p class="opacity-70">
          {gettext(
            "mnemo scans the Ren'Py save folders on this machine and keeps them in Google Drive."
          )}
        </p>
        <div>
          <.link navigate={~p"/enroll"} class="btn btn-primary" id="empty-enroll-link">
            {gettext("Add a game")}
          </.link>
        </div>
      </div>

      <div :if={@games != []} class="grid grid-cols-1 sm:grid-cols-2 gap-6" id="library-grid">
        <.game_card
          :for={game <- @games}
          game={game}
          status={@statuses[game.id] || offline_status(game)}
          drive={@drive}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :group, :list, required: true
  attr :index, :integer, required: true

  defp mirror_notice(assigns) do
    {keeper, extras} = split_group(assigns.group)
    assigns = assign(assigns, keeper: keeper, extras: extras)

    ~H"""
    <section
      class="card bg-base-200 border border-warning/40 p-6 space-y-4"
      id={"mirror-group-#{@index}"}
    >
      <div class="space-y-2">
        <h2 class="font-semibold flex items-center gap-2">
          <.icon name="hero-exclamation-triangle" class="size-5 text-warning" />
          {gettext("%{name} is enrolled more than once", name: display_name(@keeper))}
        </h2>
        <p class="text-sm opacity-80">
          {gettext(
            "Ren'Py writes this game's saves to every folder it keeps for it, and mnemo is tracking more than one of them as a game of its own. They hold the same saves, so the same slots are being filed under two histories whose generation numbers disagree."
          )}
        </p>
      </div>

      <ul class="space-y-3">
        <li class="flex items-start justify-between gap-4 flex-wrap">
          <div class="space-y-1">
            <p class="text-sm flex items-center gap-2">
              {display_name(@keeper)}
              <span class="badge badge-soft badge-success badge-sm">{gettext("Kept")}</span>
            </p>
            <p class="text-xs font-mono opacity-60 break-all">{folder(@keeper)}</p>
            <p class="text-xs opacity-60">
              {gettext("Generation %{number}", number: @keeper.last_generation_seen)}
            </p>
          </div>
        </li>
        <li
          :for={game <- @extras}
          class="flex items-start justify-between gap-4 flex-wrap border-t border-base-300 pt-3"
        >
          <div class="space-y-1">
            <p class="text-sm">{display_name(game)}</p>
            <p class="text-xs font-mono opacity-60 break-all">{folder(game)}</p>
            <p class="text-xs opacity-60">
              {gettext("Generation %{number}", number: game.last_generation_seen)}
            </p>
          </div>
          <.button
            id={"forget-#{game.id}"}
            phx-click="forget"
            phx-value-id={game.id}
            data-confirm={
              gettext(
                "Stop tracking this folder as a game of its own? The saves stay where they are."
              )
            }
          >
            {gettext("Remove this enrollment")}
          </.button>
        </li>
      </ul>

      <p class="text-xs opacity-60">
        {gettext(
          "Removing an enrollment leaves the saves on disk and everything already uploaded in Drive. It only drops mnemo's second record of this game, and the one that stays covers the same folders."
        )}
      </p>
    </section>
    """
  end

  # The folder in the OS Ren'Py root is the one worth keeping: it outlives
  # uninstalling the game, while `<gamedir>/saves` is removed with it.
  # Failing that — two portable installs of one game — the longer lineage
  # stays, because it is the one with more history to lose.
  defp split_group(group) do
    keeper =
      Enum.find(group, &(&1.install_root == "appdata")) ||
        Enum.max_by(group, & &1.last_generation_seen)

    {keeper, group -- [keeper]}
  end

  defp display_name(game), do: game.name || game.save_directory
  defp folder(game), do: Mnemo.RenPy.game_path(game) || game.save_directory

  attr :game, :map, required: true
  attr :status, :map, required: true
  attr :drive, :map, required: true

  defp game_card(assigns) do
    ~H"""
    <div class="card card-side bg-base-200 overflow-hidden" id={"game-#{@game.id}"}>
      <figure class="w-28 sm:w-36 shrink-0 bg-base-300 self-stretch">
        <.game_image
          src={~p"/covers/#{@game.id}?v=#{Mnemo.Covers.version(@game)}"}
          kind={Mnemo.Covers.kind(@game)}
          hide_on_error
        />
      </figure>
      <div class="card-body gap-2">
        <div class="flex items-start justify-between gap-2">
          <div>
            <.link navigate={~p"/games/#{@game.id}"} class="hover:underline">
              <h2 class="card-title text-base">{@game.name || @game.save_directory}</h2>
            </.link>
            <p class="text-xs opacity-50 font-mono">{@game.save_directory}</p>
          </div>
          <.status_badge status={@status} />
        </div>

        <p class="text-sm opacity-70">
          {gettext("Generation %{number}", number: @status.last_generation)} · {gettext(
            "last sync: %{time}",
            time: relative_time(@status.last_synced_at)
          )}
        </p>

        <p :if={message = detail_message(@status)} class="text-sm">{message}</p>

        <div class="card-actions justify-end mt-1">
          <.link navigate={~p"/games/#{@game.id}"} class="btn btn-ghost" id={"saves-#{@game.id}"}>
            {gettext("Saves")}
          </.link>
          <.button
            id={"sync-#{@game.id}"}
            phx-click="sync"
            phx-value-id={@game.id}
            disabled={@status.syncing? or @drive.state != :connected}
          >
            <.icon
              name="hero-arrow-path"
              class={["size-4", @status.syncing? && "motion-safe:animate-spin"]}
            /> {gettext("Sync now")}
          </.button>
        </div>
      </div>
    </div>
    """
  end
end
