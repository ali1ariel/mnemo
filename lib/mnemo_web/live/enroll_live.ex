defmodule MnemoWeb.EnrollLive do
  use MnemoWeb, :live_view

  import MnemoWeb.GameComponents

  alias Mnemo.Games.Game, as: GameSchema
  alias Mnemo.Sync.{Import, Restore}
  alias Mnemo.{Covers, Game, Games, RenPy}

  @max_archive_size 1_000_000_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Add game"))
     |> assign(enrolled: enrolled_paths())
     |> assign(import_for: nil, pending_import: nil, import_quiet: nil)
     |> allow_upload(:archive,
       accept: ~w(.zip),
       max_entries: 1,
       max_file_size: @max_archive_size,
       auto_upload: true,
       progress: &handle_archive_progress/3
     )
     |> start_scan()}
  end

  # An upload nobody committed to belongs to this view; once handed to an
  # import it does not, because enrolling navigates away and tears this
  # process down while the work is still reading the file.
  @impl true
  def terminate(_reason, socket) do
    clear_pending_import(socket)
    :ok
  end

  defp start_scan(socket) do
    socket
    |> assign(entries: nil, expanded: nil, expanded_groups: nil)
    |> assign(import_for: nil)
    |> clear_pending_import()
    |> start_async(:scan, fn -> scan_entries() end)
  end

  defp scan_entries do
    for entry <- RenPy.scan() do
      {image, kind} =
        case Covers.for_scan_entry(entry) do
          {:ok, bytes, type, kind} -> {"data:#{type};base64," <> Base.encode64(bytes), kind}
          :none -> {nil, :none}
        end

      entry |> Map.put(:preview, image) |> Map.put(:preview_kind, kind)
    end
  end

  # Compared as folders rather than as `{save_directory, root}` pairs
  # because an entry stands for every folder Ren'Py mirrors it to. A game
  # enrolled through its `<gamedir>/saves` copy has to read as enrolled
  # here too — offering it again is how one game ends up with two
  # lineages.
  defp enrolled_paths do
    for game <- Games.list(), path = RenPy.game_path(game), path != nil, do: path
  end

  @impl true
  def handle_async(:scan, {:ok, entries}, socket) do
    {:noreply, assign(socket, :entries, entries)}
  end

  def handle_async(:scan, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:entries, [])
     |> put_flash(:error, gettext("Scanning the Ren'Py folders failed."))}
  end

  @impl true
  def handle_event("rescan", _params, socket) do
    {:noreply, start_scan(socket)}
  end

  def handle_event("toggle_saves", %{"index" => index}, socket) do
    index = String.to_integer(index)
    entry = Enum.at(socket.assigns.entries || [], index)

    cond do
      socket.assigns.expanded == index ->
        {:noreply, assign(socket, expanded: nil, expanded_groups: nil)}

      entry == nil ->
        {:noreply, socket}

      true ->
        saves =
          entry.path
          |> RenPy.list_saves()
          |> Enum.map(&Map.put(&1, :src, preview_src(entry, &1)))

        {:noreply, assign(socket, expanded: index, expanded_groups: group_saves(saves))}
    end
  end

  def handle_event("enroll", %{"index" => index}, socket) do
    case entry_at(socket, index) do
      nil ->
        {:noreply, socket}

      entry ->
        case Games.enroll(enroll_attrs(entry)) do
          {:ok, game} ->
            Game.ensure_started(game.id)

            {:noreply,
             socket
             |> put_flash(:info, gettext("%{name} enrolled.", name: game.name))
             |> push_navigate(to: ~p"/")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, gettext("This game is already enrolled."))}
        end
    end
  end

  def handle_event("start_import", %{"index" => index}, socket) do
    case entry_at(socket, index) do
      nil ->
        {:noreply, socket}

      entry ->
        {:noreply,
         socket
         |> clear_pending_import()
         |> assign(import_for: String.to_integer(index))
         |> assign(import_quiet: Restore.seconds_since_write(entry.path))}
    end
  end

  def handle_event("cancel_import", _params, socket) do
    {:noreply, socket |> clear_pending_import() |> assign(import_for: nil)}
  end

  def handle_event("validate_archive", _params, socket), do: {:noreply, socket}

  def handle_event("enroll_and_import", params, socket) do
    entry = Enum.at(socket.assigns.entries || [], socket.assigns.import_for)
    pending = socket.assigns.pending_import

    opts = [
      # The folder held nothing but the reference save that proves the
      # game is installed, so the archive is the state worth having.
      mode: :replace,
      confirmed_closed: params["confirmed"] == "true",
      force: params["force"] == "true",
      discard_archive: true
    ]

    with %{} <- entry,
         %{} <- pending,
         {:ok, game} <- Games.enroll(enroll_attrs(entry)),
         :ok <- Game.import_archive(game.id, pending.path, opts) do
      {:noreply,
       socket
       |> assign(pending_import: nil, import_for: nil)
       |> put_flash(
         :info,
         gettext("%{name} was added. Importing the saves now.", name: game.name)
       )
       |> push_navigate(to: ~p"/games/#{game.id}")}
    else
      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, gettext("This game is already enrolled."))}

      {:error, :confirmation_required, _} ->
        {:noreply,
         put_flash(socket, :error, gettext("Confirm the game is closed before importing."))}

      {:error, :game_may_be_running, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("The save folder is still changing. Close the game and try again.")
         )}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not start the import."))}
    end
  end

  ## Reading the archive

  defp handle_archive_progress(:archive, upload, socket) do
    entry = Enum.at(socket.assigns.entries || [], socket.assigns.import_for)

    if upload.done? and entry do
      path = store_upload(socket, upload)
      preview = struct(GameSchema, enroll_attrs(entry))

      case Import.inspect_archive(path, preview) do
        {:ok, found} ->
          {:noreply,
           assign(socket, :pending_import, %{
             path: path,
             name: upload.client_name,
             found: found,
             plan: Import.plan(preview, found, :replace)
           })}

        {:error, :unreadable_archive, _detail} ->
          File.rm(path)

          {:noreply,
           put_flash(socket, :error, gettext("That file could not be opened as a zip archive."))}
      end
    else
      {:noreply, socket}
    end
  end

  defp store_upload(socket, upload) do
    consume_uploaded_entry(socket, upload, fn %{path: uploaded} ->
      destination =
        Path.join(System.tmp_dir!(), "mnemo-upload-#{System.unique_integer([:positive])}.zip")

      File.cp!(uploaded, destination)
      {:ok, destination}
    end)
  end

  defp clear_pending_import(socket) do
    case socket.assigns[:pending_import] do
      %{path: path} -> File.rm(path)
      _ -> :ok
    end

    assign(socket, pending_import: nil)
  end

  defp entry_at(socket, index),
    do: Enum.at(socket.assigns.entries || [], String.to_integer(index))

  defp enroll_attrs(entry) do
    install_root = if entry.root == RenPy.default_root(), do: "appdata", else: entry.root

    %{
      save_directory: entry.save_directory,
      install_root: install_root,
      install_path: entry[:install],
      name: entry.name
    }
  end

  defp preview_src(_entry, %{screenshot?: false}), do: nil

  defp preview_src(entry, save) do
    ~p"/scan/preview?root=#{entry.root}&dir=#{entry.save_directory}&file=#{save.file}&v=#{DateTime.to_unix(save.mtime)}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-lg font-semibold">{gettext("Add game")}</h1>
          <p class="text-sm opacity-70">
            {gettext("Games found in the Ren'Py save folders on this machine.")}
          </p>
        </div>
        <.button id="rescan" phx-click="rescan">{gettext("Rescan")}</.button>
      </div>

      <section class="card bg-base-200 p-6 space-y-3" id="enroll-help">
        <h2 class="font-semibold">{gettext("Enrolling, and bringing old saves back")}</h2>
        <p class="text-sm opacity-80">
          {gettext(
            "mnemo never creates a save folder — it only lists folders a game already made. That is why a game has to be launched once and quit before it shows up here: Ren'Py writes the folder on first launch."
          )}
        </p>
        <p class="text-sm opacity-80">
          {gettext(
            "So the save sitting in a freshly installed game is there to identify the folder, nothing more. If your real saves are in a zip — a backup you made or a Google Takeout export — use %{button} instead of %{enroll}: it enrols the game and puts your archive in place of what the folder holds now.",
            button: gettext("Import saves"),
            enroll: gettext("Enroll")
          )}
        </p>
        <p class="text-sm opacity-80">
          {gettext(
            "What gets replaced is published as a generation first, so it stays in the history and can be restored. Files Ren'Py keeps outside the synced set are carried across untouched."
          )}
        </p>
      </section>

      <div :if={@entries == nil} class="card bg-base-200 p-10 text-center" id="scan-loading">
        <p class="flex items-center justify-center gap-2 text-sm opacity-70">
          <.icon name="hero-arrow-path" class="size-4 motion-safe:animate-spin" />
          {gettext("Scanning…")}
        </p>
      </div>

      <div :if={@entries == []} class="card bg-base-200 p-10 text-center space-y-2" id="scan-empty">
        <h2 class="font-semibold">{gettext("No Ren'Py games found")}</h2>
        <p class="text-sm opacity-70">
          {gettext(
            "If a game is installed but not listed, launch it once and quit — Ren'Py creates its save folder on first launch."
          )}
        </p>
      </div>

      <div :if={@entries && @entries != []} class="space-y-4" id="scan-results">
        <div
          :for={{entry, index} <- Enum.with_index(@entries)}
          class="card bg-base-200 overflow-hidden"
          id={"scan-entry-#{index}"}
        >
          <div class="sm:flex">
            <figure class="sm:w-40 shrink-0 bg-base-300 aspect-video sm:aspect-auto self-stretch">
              <.game_image
                :if={entry.preview}
                src={entry.preview}
                kind={entry.preview_kind}
              />
              <div :if={entry.preview == nil} class="p-6 text-xs opacity-40">
                {gettext("no screenshot")}
              </div>
            </figure>
            <div class="card-body gap-1">
              <div class="flex items-center gap-2 flex-wrap">
                <div class="flex items-baseline gap-2">
                  <h2 class="card-title text-base">{entry.name}</h2>
                  <span
                    :if={enrolled?(@enrolled, entry)}
                    class="badge badge-soft badge-success"
                  >
                    {gettext("Enrolled")}
                  </span>
                </div>
                <span :if={entry.kind == :portable} class="badge badge-soft badge-info badge-sm">
                  {gettext("game install folder")}
                </span>
              </div>
              <p class="text-xs opacity-50 font-mono break-all">{entry.path}</p>
              <div :if={entry.mirrors != []} class="text-xs opacity-60">
                {ngettext(
                  "Ren'Py keeps a second copy of these saves, mirrored automatically:",
                  "Ren'Py keeps other copies of these saves, mirrored automatically:",
                  length(entry.mirrors)
                )}
                <p :for={mirror <- entry.mirrors} class="font-mono opacity-70 break-all">
                  {mirror}
                </p>
              </div>
              <p class="text-sm opacity-70">
                {ngettext("%{count} save", "%{count} saves", entry.save_count)}
                <span :if={entry.latest_save_at}>
                  · {gettext("last played: %{time}", time: relative_time(entry.latest_save_at))}
                </span>
              </p>
              <div class="card-actions justify-end mt-2">
                <.button
                  :if={entry.save_count > 0}
                  id={"preview-#{index}"}
                  variant="secondary"
                  phx-click="toggle_saves"
                  phx-value-index={index}
                >
                  {if @expanded == index, do: gettext("Hide saves"), else: gettext("Preview saves")}
                </.button>
                <.button
                  :if={not enrolled?(@enrolled, entry) and @import_for != index}
                  id={"import-#{index}"}
                  phx-click="start_import"
                  phx-value-index={index}
                >
                  <.icon name="hero-arrow-up-tray" class="size-4" /> {gettext("Import saves")}
                </.button>
                <.button
                  :if={not enrolled?(@enrolled, entry)}
                  id={"enroll-#{index}"}
                  variant="primary"
                  phx-click="enroll"
                  phx-value-index={index}
                >
                  {gettext("Enroll")}
                </.button>
              </div>
            </div>
          </div>
          <.import_panel
            :if={@import_for == index}
            index={index}
            entry={entry}
            pending={@pending_import}
            uploads={@uploads}
            seconds_since_write={@import_quiet}
          />

          <div
            :if={@expanded == index}
            class="border-t border-base-300 p-4"
            id={"scan-entry-saves-#{index}"}
          >
            <.saves_browser :if={not @expanded_groups.empty?} groups={@expanded_groups} />
            <p :if={@expanded_groups.empty?} class="text-sm opacity-70">
              {gettext("No save slots here yet.")}
            </p>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp enrolled?(enrolled, entry) do
    locations = [entry.path | entry.mirrors]
    Enum.any?(enrolled, fn path -> Enum.any?(locations, &RenPy.same_directory?(path, &1)) end)
  end

  attr :index, :integer, required: true
  attr :entry, :map, required: true
  attr :pending, :map, default: nil
  attr :uploads, :map, required: true
  attr :seconds_since_write, :integer, default: nil

  defp import_panel(assigns) do
    ~H"""
    <div class="border-t border-base-300 p-4 space-y-4" id={"import-panel-#{@index}"}>
      <div>
        <h3 class="font-medium">
          {gettext("Import saves into %{name}", name: @entry.name)}
        </h3>
        <p class="text-sm opacity-70">
          {ngettext(
            "The %{count} save in this folder will be replaced by what the archive holds. It is published as a generation first, so it stays recoverable.",
            "The %{count} saves in this folder will be replaced by what the archive holds. They are published as a generation first, so they stay recoverable.",
            @entry.save_count
          )}
        </p>
      </div>

      <form :if={@pending == nil} id={"archive-form-#{@index}"} phx-change="validate_archive">
        <.archive_dropzone id={"archive-dropzone-#{@index}"} upload={@uploads.archive} />
      </form>

      <div :if={@pending} id={"import-preview-#{@index}"} class="space-y-4">
        <div class="flex items-baseline justify-between gap-4 flex-wrap">
          <p class="text-sm font-mono truncate">{@pending.name}</p>
          <.archive_summary found={@pending.found} />
        </div>

        <p :if={@pending.found.entries == []} class="text-sm" id={"import-nothing-#{@index}"}>
          {gettext(
            "No Ren'Py saves in this archive. mnemo looks for files named the way Ren'Py names them, such as 1-1-LT1.save."
          )}
        </p>

        <%!-- Everything in the folder is going away, so pointing out which
        entries match a file already there would only be noise. --%>
        <.archive_entries
          :if={@pending.found.entries != []}
          entries={@pending.found.entries}
          mark_existing={false}
        />

        <form
          :if={@pending.found.entries != []}
          id={"import-form-#{@index}"}
          phx-submit="enroll_and_import"
          class="space-y-3 border-t border-base-300 pt-4"
        >
          <p class="text-sm">
            {ngettext(
              "%{count} save will be written.",
              "%{count} saves will be written.",
              length(@pending.plan.write)
            )}
          </p>
          <p :if={recent_write?(@seconds_since_write)} class="text-sm text-warning">
            {gettext("Something wrote to this folder %{time} — the game may still be open.",
              time: relative_time(DateTime.add(DateTime.utc_now(), -(@seconds_since_write || 0)))
            )}
          </p>
          <label class="flex items-center gap-2 text-sm">
            <input
              type="checkbox"
              name="confirmed"
              value="true"
              class="checkbox checkbox-sm"
              required
            />
            {gettext("The game is closed")}
          </label>
          <input :if={recent_write?(@seconds_since_write)} type="hidden" name="force" value="true" />

          <div class="flex gap-2">
            <.button variant="primary" id={"confirm-import-#{@index}"}>
              {gettext("Enroll and import")}
            </.button>
            <button
              type="button"
              class="btn btn-ghost"
              phx-click="cancel_import"
              id={"cancel-import-#{@index}"}
            >
              {gettext("Cancel")}
            </button>
          </div>
        </form>

        <button
          :if={@pending.found.entries == []}
          type="button"
          class="btn btn-ghost"
          phx-click="cancel_import"
          id={"cancel-import-empty-#{@index}"}
        >
          {gettext("Pick another file")}
        </button>
      </div>
    </div>
    """
  end

  defp recent_write?(nil), do: false
  defp recent_write?(seconds), do: seconds < 60
end
