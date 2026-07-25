defmodule MnemoWeb.GameComponents do
  @moduledoc "Game cards, sync status and screenshot display shared across screens."

  use MnemoWeb, :html

  @doc """
  A screenshot that is blurred until clicked.

  Save screenshots are arbitrary game frames and cannot be assumed safe
  for work, so nothing renders sharp by default. The reveal is a hidden
  checkbox toggled by the label — no JavaScript, works in dead renders,
  and clicking again re-blurs.
  """
  attr :src, :string, required: true
  attr :alt, :string, default: ""
  attr :hide_on_error, :boolean, default: false

  def censored_image(assigns) do
    ~H"""
    <label
      class="relative block h-full w-full cursor-pointer overflow-hidden select-none"
      title={gettext("Click to reveal or hide")}
    >
      <input type="checkbox" class="peer sr-only" />
      <img
        src={@src}
        alt={@alt}
        loading="lazy"
        class="h-full w-full object-cover blur-xl scale-110 transition-all duration-300 peer-checked:blur-none peer-checked:scale-100"
        onerror={@hide_on_error && "this.closest('label').style.display='none'"}
      />
      <span class="absolute inset-0 grid place-items-center pointer-events-none peer-checked:hidden">
        <span class="rounded-full bg-base-100/70 p-2">
          <.icon name="hero-eye-slash" class="size-5" />
        </span>
      </span>
    </label>
    """
  end

  @doc """
  Group a `Mnemo.RenPy.list_saves/1` result the way the slot screens show
  it: regular saves per page, autosaves and quicksaves newest first.

  Each save map is expected to carry a `:src` key with the screenshot URL
  (nil when the save has none) — the caller decides how slots are
  addressed, since enrolled games and scanned folders use different
  routes.
  """
  def group_saves(saves) do
    {slots, rest} = Enum.split_with(saves, &match?({:slot, _, _}, &1.slot))

    pages =
      slots
      |> Enum.group_by(fn save -> elem(save.slot, 1) end)
      |> Enum.sort_by(fn {page, _} -> page end)
      |> Enum.map(fn {page, page_saves} ->
        {page, Enum.sort_by(page_saves, &natural_key(elem(&1.slot, 2)))}
      end)

    %{
      pages: pages,
      autos: rest |> Enum.filter(&match?({:auto, _}, &1.slot)) |> newest_first(),
      quicks: rest |> Enum.filter(&match?({:quick, _}, &1.slot)) |> newest_first(),
      empty?: saves == []
    }
  end

  defp newest_first(saves), do: Enum.sort_by(saves, & &1.mtime, {:desc, DateTime})

  # "Save Slot 9" must sort before "Save Slot 10".
  defp natural_key(name) do
    name
    |> String.downcase()
    |> String.split(~r/(\d+)/, include_captures: true, trim: true)
    |> Enum.map(fn part ->
      case Integer.parse(part) do
        {n, ""} -> n
        _ -> part
      end
    end)
  end

  attr :groups, :map, required: true

  def saves_browser(assigns) do
    ~H"""
    <div class="space-y-6">
      <p class="text-xs opacity-60">
        {gettext("Screenshots are blurred; click one to reveal or hide it.")}
      </p>

      <section :for={{page, saves} <- @groups.pages} class="space-y-3" id={"page-#{page}"}>
        <h2 class="font-semibold">{gettext("Page %{page}", page: page)}</h2>
        <.slot_grid saves={saves} />
      </section>

      <section :if={@groups.autos != []} class="space-y-3" id="autosaves">
        <h2 class="font-semibold">{gettext("Autosaves")}</h2>
        <.slot_grid saves={@groups.autos} />
      </section>

      <section :if={@groups.quicks != []} class="space-y-3" id="quicksaves">
        <h2 class="font-semibold">{gettext("Quicksaves")}</h2>
        <.slot_grid saves={@groups.quicks} />
      </section>
    </div>
    """
  end

  attr :saves, :list, required: true

  defp slot_grid(assigns) do
    ~H"""
    <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-4">
      <.slot_card :for={save <- @saves} save={save} />
    </div>
    """
  end

  attr :save, :map, required: true

  defp slot_card(assigns) do
    ~H"""
    <div class="card bg-base-200 overflow-hidden" id={"slot-#{dom_id(@save.file)}"}>
      <figure class="aspect-video bg-base-300">
        <.censored_image :if={@save.src} src={@save.src} />
        <div :if={@save.src == nil} class="grid h-full w-full place-items-center text-xs opacity-40">
          {gettext("no screenshot")}
        </div>
      </figure>
      <div class="card-body p-3 gap-1">
        <p class="text-sm font-medium">{slot_title(@save.slot)}</p>
        <p :if={@save.save_name} class="text-sm italic opacity-80">{@save.save_name}</p>
        <p class="text-xs opacity-60">
          {relative_time(@save.mtime)} · {format_bytes(@save.size)}
        </p>
      </div>
    </div>
    """
  end

  defp slot_title({:slot, _page, name}), do: name
  defp slot_title({:auto, n}), do: gettext("Autosave %{n}", n: n)
  defp slot_title({:quick, n}), do: gettext("Quicksave %{n}", n: n)

  defp dom_id(file), do: String.replace(file, ~r/[^A-Za-z0-9]+/, "-")

  attr :status, :map, required: true

  def status_badge(assigns) do
    {class, label} =
      case assigns.status.status do
        :idle -> {"badge-ghost", gettext("Idle")}
        :snapshotting -> {"badge-info", gettext("Snapshotting…")}
        :uploading -> {"badge-info", gettext("Uploading…")}
        :safety_snapshot -> {"badge-info", gettext("Saving current state…")}
        :downloading -> {"badge-info", gettext("Downloading…")}
        :swapping -> {"badge-info", gettext("Putting files in place…")}
        :ok -> {"badge-success", gettext("Synced")}
        :restored -> {"badge-success", gettext("Restored")}
        :resolved -> {"badge-success", gettext("Resolved")}
        :conflict -> {"badge-warning", gettext("Conflict")}
        :error -> {"badge-error", gettext("Error")}
      end

    assigns = assign(assigns, class: class, label: label)

    ~H"""
    <span class={["badge badge-soft whitespace-nowrap", @class]}>{@label}</span>
    """
  end

  def detail_message(%{status: :resolved, detail: %{resolution: :keep_local}}) do
    gettext("Kept this device's files. The other version stays in the history.")
  end

  def detail_message(%{status: :resolved, detail: %{resolution: :keep_remote}}) do
    gettext(
      "Took the other device's files. This device's version was saved to the history first."
    )
  end

  def detail_message(%{status: :restored, detail: detail}) do
    base = gettext("Generation %{number} is back in place.", number: detail[:generation])

    case detail[:safety] do
      {:unavailable, _} ->
        base <>
          " " <>
          gettext(
            "The previous files could not be published as a generation, so they were kept in a backup folder."
          )

      _ ->
        base <> " " <> gettext("The previous state was saved first, so this is undoable.")
    end
  end

  def detail_message(%{status: :ok, detail: %{result: :no_changes}}),
    do: gettext("Already up to date.")

  def detail_message(%{status: :ok, detail: %{generation: n, uploaded: uploaded}}) do
    gettext("Generation %{number} uploaded.", number: n) <>
      " " <> ngettext("%{count} new file.", "%{count} new files.", uploaded)
  end

  def detail_message(%{status: :conflict, detail: detail}) do
    reason =
      case detail[:reason] do
        :foreign_lineage ->
          gettext("This game already has history in Drive from another install.")

        :remote_ahead ->
          gettext("Another device synced newer generations.")

        :remote_behind ->
          gettext("The remote history is behind this device.")

        :fork ->
          gettext("Two devices wrote the same generation.")

        _ ->
          gettext("The local and remote histories diverged.")
      end

    reason <> " " <> gettext("Nothing was overwritten. Pick which side to keep below.")
  end

  def detail_message(%{status: :error, detail: detail}) do
    case detail do
      %{tag: :no_saves} ->
        gettext("No saves found. Launch the game once, quit, and try again.")

      %{tag: :invalid_save, file: file} ->
        gettext("A save file failed validation and was not uploaded: %{file}", file: file)

      %{tag: :missing_folder, path: path} ->
        gettext("Save folder not found: %{path}", path: path)

      %{tag: :upload_failed} ->
        gettext("Upload failed. Nothing was committed; try again.")

      %{tag: :drive} ->
        gettext("A Google Drive request failed. Try again.")

      %{tag: :crashed} ->
        gettext("The sync crashed unexpectedly.")

      %{tag: :download_failed} ->
        gettext("A file could not be downloaded intact. Nothing on disk was touched.")

      %{tag: :swap_failed} ->
        gettext("Putting the files in place failed. The previous folder was left as it was.")

      %{tag: :empty_generation} ->
        gettext("That generation has no files recorded.")

      _ ->
        gettext("The sync failed.")
    end
  end

  def detail_message(_status), do: nil
end
