defmodule MnemoWeb.SlotsLive do
  @moduledoc """
  The slot grid for one game, the way Ren'Py renders it: regular saves
  grouped by page, autosaves and quicksaves in their own sections.
  """

  use MnemoWeb, :live_view

  import MnemoWeb.GameComponents

  alias Mnemo.{Drive, Game, Games, RenPy, Sync}
  alias Mnemo.Sync.{Conflict, Restore}

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
       |> assign(confirm_restore: nil)
       |> assign_saves()
       |> assign_history()
       |> assign_conflict()}
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

  defp assign_history(socket) do
    game = socket.assigns.game

    socket
    |> assign(generations: Sync.list_generations(game.id))
    |> assign(backups: Restore.list_backups(game))
    |> assign(
      seconds_since_write: socket.assigns.path && Restore.seconds_since_write(socket.assigns.path)
    )
  end

  # Reading both sides talks to Drive, so it only happens when the engine
  # actually reported a divergence.
  defp assign_conflict(socket) do
    if socket.assigns.status.status == :conflict do
      case Conflict.sides(socket.assigns.game) do
        {:ok, sides} -> assign(socket, :sides, sides)
        _ -> assign(socket, :sides, nil)
      end
    else
      assign(socket, :sides, nil)
    end
  end

  @impl true
  def handle_info({:game, game_id, status}, %{assigns: %{game: %{id: game_id}}} = socket) do
    socket = assign(socket, :status, status)

    # A finished restore or sync changed the folder on disk, so the slot
    # grid and the history have to be read again.
    socket =
      if status.syncing? do
        socket
      else
        socket
        |> assign(game: Games.get(game_id) || socket.assigns.game)
        |> assign_saves()
        |> assign_history()
        |> assign_conflict()
      end

    {:noreply, socket}
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

  def handle_event("ask_restore", %{"number" => number}, socket) do
    {:noreply,
     socket
     |> assign(confirm_restore: String.to_integer(number))
     |> assign_history()}
  end

  def handle_event("cancel_restore", _params, socket) do
    {:noreply, assign(socket, confirm_restore: nil)}
  end

  def handle_event("restore", %{"number" => number} = params, socket) do
    opts = [
      confirmed_closed: params["confirmed"] == "true",
      force: params["force"] == "true"
    ]

    case Game.restore(socket.assigns.game.id, String.to_integer(number), opts) do
      :ok ->
        {:noreply, assign(socket, confirm_restore: nil)}

      {:error, :confirmation_required, _} ->
        {:noreply,
         put_flash(socket, :error, gettext("Confirm the game is closed before restoring."))}

      {:error, :game_may_be_running, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("The save folder is still changing. Close the game and try again.")
         )}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, gettext("A sync is already running."))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not start the restore."))}
    end
  end

  def handle_event("save_options", params, socket) do
    attrs = %{
      name: String.trim(params["name"] || ""),
      sync_autosaves: params["sync_autosaves"] == "true"
    }

    attrs = if attrs.name == "", do: Map.delete(attrs, :name), else: attrs

    case Games.update_game(socket.assigns.game, attrs) do
      {:ok, game} ->
        {:noreply,
         socket
         |> assign(game: game)
         |> assign(page_title: game.name || game.save_directory)
         |> assign_saves()
         |> put_flash(:info, gettext("Options saved."))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save the options."))}
    end
  end

  def handle_event("resolve", %{"choice" => choice} = params, socket) do
    choice = if choice == "keep_remote", do: :keep_remote, else: :keep_local
    opts = [confirmed_closed: params["confirmed"] == "true", force: true]

    case Game.resolve_conflict(socket.assigns.game.id, choice, opts) do
      :ok ->
        {:noreply, socket}

      {:error, :confirmation_required, _} ->
        {:noreply,
         put_flash(socket, :error, gettext("Confirm the game is closed before restoring."))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not resolve the conflict."))}
    end
  end

  def handle_event("rollback", %{"path" => path}, socket) do
    case Restore.rollback(socket.assigns.game, path) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("The previous folder is back in place."))
         |> assign_saves()
         |> assign_history()}

      {:error, _tag, _detail} ->
        {:noreply, put_flash(socket, :error, gettext("Could not roll back."))}
    end
  end

  def handle_event("discard_backup", %{"path" => path}, socket) do
    case Restore.discard(socket.assigns.game, path) do
      :ok ->
        {:noreply, socket |> put_flash(:info, gettext("Backup deleted.")) |> assign_history()}

      {:error, _tag, _detail} ->
        {:noreply, put_flash(socket, :error, gettext("Could not delete the backup."))}
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

      <.conflict_panel :if={@sides} sides={@sides} syncing?={@status.syncing?} />

      <div :if={@groups.empty?} id="no-saves" class="card bg-base-200 p-10 text-center space-y-2">
        <h2 class="font-semibold">
          {gettext("No saves found. Launch the game once, quit, and try again.")}
        </h2>
      </div>

      <.saves_browser :if={not @groups.empty?} groups={@groups} />

      <section :if={@backups != []} class="space-y-3" id="backups">
        <h2 class="font-semibold">{gettext("Backup folders")}</h2>
        <p class="text-sm opacity-70">
          {gettext(
            "A restore left these behind because the previous files were not published as a generation. Roll one back to undo, or delete it once you are sure."
          )}
        </p>
        <div
          :for={backup <- @backups}
          class="card bg-base-200 p-4 flex-row items-center justify-between gap-4"
          id={"backup-#{dom_id(backup.name)}"}
        >
          <div class="min-w-0">
            <p class="text-sm font-mono truncate">{backup.name}</p>
            <p class="text-xs opacity-60">{relative_time(backup.created_at)}</p>
          </div>
          <div class="flex gap-2 shrink-0">
            <.button
              phx-click="rollback"
              phx-value-path={backup.path}
              data-confirm={gettext("Put this folder back and move the current one aside?")}
            >
              {gettext("Roll back")}
            </.button>
            <.button
              phx-click="discard_backup"
              phx-value-path={backup.path}
              data-confirm={gettext("Delete this backup folder permanently?")}
            >
              {gettext("Delete")}
            </.button>
          </div>
        </div>
      </section>

      <section class="card bg-base-200 p-6 space-y-4" id="game-options">
        <h2 class="font-semibold">{gettext("Options")}</h2>
        <form phx-submit="save_options" id="options-form" class="space-y-4">
          <label class="block space-y-1">
            <span class="text-sm font-medium">{gettext("Name")}</span>
            <input
              type="text"
              name="name"
              value={@game.name}
              class="input input-bordered w-full"
              autocomplete="off"
            />
          </label>

          <label class="flex items-start gap-3">
            <input
              type="checkbox"
              name="sync_autosaves"
              value="true"
              checked={@game.sync_autosaves}
              class="checkbox mt-0.5"
            />
            <span class="text-sm">
              <span class="font-medium">{gettext("Back up autosaves and quicksaves")}</span>
              <span class="block opacity-70">
                {gettext(
                  "Off by default: Ren'Py rewrites them every few minutes, which multiplies generations. With this off they are never uploaded, so they cannot be restored either."
                )}
              </span>
            </span>
          </label>

          <.button variant="primary" id="save-options">{gettext("Save options")}</.button>
        </form>
      </section>

      <section :if={@generations != []} class="space-y-3" id="history">
        <h2 class="font-semibold">{gettext("History")}</h2>
        <div
          :for={generation <- @generations}
          class="card bg-base-200 p-4 space-y-3"
          id={"generation-#{generation.number}"}
        >
          <div class="flex items-center justify-between gap-4">
            <div>
              <p class="text-sm font-medium">
                {gettext("Generation %{number}", number: generation.number)}
                <span :if={generation.number == @status.last_generation} class="badge badge-sm ml-1">
                  {gettext("current")}
                </span>
              </p>
              <p class="text-xs opacity-60">
                {relative_time(generation.inserted_at)} · {ngettext(
                  "%{count} file",
                  "%{count} files",
                  length(generation.manifest)
                )} · {format_bytes(generation.byte_size)}
              </p>
            </div>
            <.button
              :if={@confirm_restore != generation.number}
              id={"restore-#{generation.number}"}
              phx-click="ask_restore"
              phx-value-number={generation.number}
              disabled={@status.syncing?}
            >
              {gettext("Restore")}
            </.button>
          </div>

          <.restore_confirmation
            :if={@confirm_restore == generation.number}
            number={generation.number}
            seconds_since_write={@seconds_since_write}
          />
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :sides, :map, required: true
  attr :syncing?, :boolean, default: false

  defp conflict_panel(assigns) do
    ~H"""
    <section
      id="conflict"
      class="rounded-box border border-warning/40 bg-warning/5 p-6 space-y-4"
    >
      <div>
        <h2 class="font-semibold flex items-center gap-2">
          <.icon name="hero-exclamation-triangle" class="size-5 text-warning" />
          {gettext("Two devices changed this game")}
        </h2>
        <p class="text-sm opacity-80 mt-1">
          {gettext(
            "Saves cannot be merged, so pick which side goes on disk. Nothing is deleted either way — both versions stay in the history."
          )}
        </p>
      </div>

      <div :if={@sides.forked?} class="text-sm text-warning" id="conflict-fork">
        {gettext(
          "Two devices also published the same generation number. Resolving that needs a newer version of mnemo; nothing here will overwrite your saves."
        )}
      </div>

      <div class="grid gap-4 sm:grid-cols-2">
        <div class="card bg-base-100 p-4 space-y-2" id="conflict-local">
          <h3 class="font-medium text-sm">{gettext("This device")}</h3>
          <p class="text-xs opacity-60">
            {gettext("Generation %{number}", number: @sides.local.generation)} · {ngettext(
              "%{count} file",
              "%{count} files",
              length(@sides.local.files)
            )}
          </p>
          <.button
            id="keep-local"
            phx-click="resolve"
            phx-value-choice="keep_local"
            disabled={@syncing? or @sides.forked?}
          >
            {gettext("Keep these files")}
          </.button>
        </div>

        <div class="card bg-base-100 p-4 space-y-2" id="conflict-remote">
          <h3 class="font-medium text-sm">{gettext("The other device")}</h3>
          <p class="text-xs opacity-60">
            {gettext("Generation %{number}", number: @sides.remote.generation)} · {ngettext(
              "%{count} file",
              "%{count} files",
              length(@sides.remote.files)
            )}
          </p>
          <p class="text-xs opacity-60 font-mono truncate" title={@sides.remote.device_id}>
            {@sides.remote.device_id}
          </p>
          <form phx-submit="resolve" id="keep-remote-form" class="space-y-2">
            <input type="hidden" name="choice" value="keep_remote" />
            <label class="flex items-center gap-2 text-xs">
              <input
                type="checkbox"
                name="confirmed"
                value="true"
                class="checkbox checkbox-sm"
                required
              />
              {gettext("The game is closed")}
            </label>
            <.button id="keep-remote" disabled={@syncing? or @sides.forked?}>
              {gettext("Take these files")}
            </.button>
          </form>
        </div>
      </div>

      <div :if={@sides.diverging != []}>
        <h3 class="font-medium text-sm mb-2">
          {ngettext("%{count} slot differs", "%{count} slots differ", length(@sides.diverging))}
        </h3>
        <ul class="text-sm space-y-1">
          <li :for={item <- @sides.diverging} class="flex items-center gap-2">
            <span class={[
              "badge badge-sm shrink-0",
              item.state == :only_local && "badge-info",
              item.state == :only_remote && "badge-warning"
            ]}>
              {divergence_label(item.state)}
            </span>
            <span class="font-mono text-xs truncate">{item.rel_path}</span>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  defp divergence_label(:only_local), do: gettext("only here")
  defp divergence_label(:only_remote), do: gettext("only there")
  defp divergence_label(:changed), do: gettext("different")

  attr :number, :integer, required: true
  attr :seconds_since_write, :integer, default: nil

  # Restoring under a running game is the one way mnemo can destroy data:
  # Ren'Py rewrites everything from memory when it exits, so the player
  # would watch a "success" message and lose the restore anyway.
  defp restore_confirmation(assigns) do
    assigns = assign(assigns, :recent?, recent_write?(assigns.seconds_since_write))

    ~H"""
    <.form
      for={%{}}
      as={:restore}
      id={"restore-form-#{@number}"}
      phx-submit="restore"
      class="rounded-box border border-warning/40 bg-warning/5 p-4 space-y-3"
    >
      <input type="hidden" name="number" value={@number} />
      <p class="text-sm font-medium">
        {gettext("Replace the current saves with generation %{number}?", number: @number)}
      </p>
      <p class="text-sm opacity-80">
        {gettext(
          "The files on disk now are saved as a new generation first, so you can come back to them."
        )}
      </p>
      <p :if={@recent?} class="text-sm text-warning">
        {gettext("Something wrote to this folder %{time} — the game may still be open.",
          time: relative_time(DateTime.add(DateTime.utc_now(), -(@seconds_since_write || 0)))
        )}
      </p>
      <label class="flex items-center gap-2 text-sm">
        <input type="checkbox" name="confirmed" value="true" class="checkbox checkbox-sm" required />
        {gettext("The game is closed")}
      </label>
      <input :if={@recent?} type="hidden" name="force" value="true" />
      <div class="flex gap-2">
        <.button variant="primary" id={"confirm-restore-#{@number}"}>
          {gettext("Restore")}
        </.button>
        <button type="button" class="btn btn-ghost" phx-click="cancel_restore">
          {gettext("Cancel")}
        </button>
      </div>
    </.form>
    """
  end

  defp recent_write?(nil), do: false
  defp recent_write?(seconds), do: seconds < 60

  defp dom_id(name), do: String.replace(name, ~r/[^A-Za-z0-9]+/, "-")
end
