defmodule MnemoWeb.EnrollLive do
  use MnemoWeb, :live_view

  import MnemoWeb.GameComponents

  alias Mnemo.{Covers, Game, Games, RenPy}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Add game"))
     |> assign(enrolled: enrolled_set())
     |> start_scan()}
  end

  defp start_scan(socket) do
    socket
    |> assign(entries: nil, expanded: nil, expanded_groups: nil)
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

  defp enrolled_set do
    MapSet.new(Games.list(), fn game ->
      {game.save_directory, RenPy.resolve_root(game.install_root)}
    end)
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
    entry = Enum.at(socket.assigns.entries || [], String.to_integer(index))

    if entry == nil do
      {:noreply, socket}
    else
      install_root =
        if entry.root == RenPy.default_root(), do: "appdata", else: entry.root

      attrs = %{
        save_directory: entry.save_directory,
        install_root: install_root,
        install_path: entry[:install],
        name: entry.name
      }

      case Games.enroll(attrs) do
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
                <h2 class="card-title text-base">{entry.name}</h2>
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
                  class="btn btn-ghost"
                  phx-click="toggle_saves"
                  phx-value-index={index}
                >
                  {if @expanded == index, do: gettext("Hide saves"), else: gettext("Preview saves")}
                </.button>
                <span
                  :if={enrolled?(@enrolled, entry)}
                  class="badge badge-soft badge-success"
                >
                  {gettext("Enrolled")}
                </span>
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

  defp enrolled?(enrolled, entry),
    do: MapSet.member?(enrolled, {entry.save_directory, entry.root})
end
