defmodule MnemoWeb.SettingsLive do
  use MnemoWeb, :live_view

  import MnemoWeb.DriveComponents

  alias Mnemo.Drive.ClientFile
  alias Mnemo.{Drive, Settings}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Drive.subscribe()

    {:ok,
     socket
     |> assign(page_title: gettext("Settings"))
     |> assign(drive: Drive.status())
     |> assign_credentials_form()
     |> assign_cover_form()
     |> assign_language_form()
     |> allow_upload(:client_file,
       accept: ~w(.json application/json),
       max_entries: 1,
       max_file_size: 65_536,
       auto_upload: true,
       progress: &handle_progress/3
     )}
  end

  defp assign_credentials_form(socket) do
    client = Drive.resolve_client()

    socket
    |> assign(:secret_set?, client != nil and client.client_secret != nil)
    |> assign(:credentials_saved?, client != nil)
    |> assign(:credentials_editing?, client == nil)
    |> assign(
      :credentials_form,
      to_form(%{"client_id" => (client && client.client_id) || "", "client_secret" => ""},
        as: :credentials
      )
    )
  end

  defp assign_cover_form(socket) do
    key_set? = Settings.get("steamgriddb_api_key") not in [nil, ""]

    socket
    |> assign(:cover_key_set?, key_set?)
    |> assign(:cover_editing?, not key_set?)
    |> assign(:cover_form, to_form(%{"steamgriddb_api_key" => ""}, as: :cover))
  end

  defp assign_language_form(socket) do
    assign(
      socket,
      :language_form,
      to_form(%{"locale" => Settings.locale() || ""}, as: :language)
    )
  end

  defp handle_progress(:client_file, entry, socket) do
    if entry.done? do
      parsed =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, with({:ok, raw} <- File.read(path), do: ClientFile.parse(raw))}
        end)

      {:noreply, apply_import(socket, parsed)}
    else
      {:noreply, socket}
    end
  end

  defp apply_import(socket, {:ok, client}) do
    store_credentials(socket, client.client_id, client.client_secret)
  end

  defp apply_import(socket, {:error, reason}) do
    put_flash(socket, :error, import_error_message(reason))
  end

  defp store_credentials(socket, client_id, client_secret) do
    Settings.put_google_client_id(client_id)

    # Blank means "keep the stored one", so an existing secret survives a
    # save that only changes the id.
    if client_secret != "" do
      Settings.put_google_client_secret(client_secret)
    end

    Drive.reload_client()
    drive = Drive.status()

    message =
      if drive.state == :connected do
        gettext("Credentials saved.")
      else
        gettext("Credentials saved. Now authorize access in step 2 below.")
      end

    socket
    |> assign(drive: drive)
    |> assign_credentials_form()
    |> put_flash(:info, message)
  end

  defp import_error_message(:wrong_client_type) do
    gettext(
      "This file belongs to a \"Web application\" client. mnemo needs one of type \"Desktop app\" — create a new client with that type and download it again."
    )
  end

  defp import_error_message(:invalid_json) do
    gettext("That file is not valid JSON. Download it again from the Google console.")
  end

  defp import_error_message(:too_large) do
    gettext("That file is too large to be an OAuth client file.")
  end

  defp import_error_message(_reason) do
    gettext(
      "This JSON does not look like a Google OAuth client file. It should be the one downloaded under \"Clients\" in the console."
    )
  end

  defp upload_error_message(:too_large), do: gettext("File is too large.")
  defp upload_error_message(:not_accepted), do: gettext("Only .json files are accepted.")
  defp upload_error_message(_error), do: gettext("That file could not be read.")

  attr :drive, :map, required: true

  defp connection_badge(assigns) do
    {class, label} =
      case assigns.drive.state do
        :connected -> {"badge-success", gettext("Connected")}
        :connecting -> {"badge-info", gettext("Waiting…")}
        :reconnect_required -> {"badge-warning", gettext("Reconnect needed")}
        _ -> {"badge-ghost", gettext("Pending")}
      end

    assigns = assign(assigns, class: class, label: label)

    ~H"""
    <span class={["badge badge-soft whitespace-nowrap", @class]}>{@label}</span>
    """
  end

  attr :href, :string, required: true
  attr :label, :string, default: nil

  defp guide_link(assigns) do
    ~H"""
    <a href={@href} target="_blank" rel="noreferrer" class="link whitespace-nowrap">
      {@label || gettext("open in the console")}
    </a>
    """
  end

  @impl true
  def handle_info({:drive, status}, socket) do
    {:noreply, assign(socket, :drive, status)}
  end

  @impl true
  def handle_event("save_credentials", %{"credentials" => params}, socket) do
    client_id = String.trim(params["client_id"] || "")
    client_secret = String.trim(params["client_secret"] || "")

    if client_id == "" do
      {:noreply, put_flash(socket, :error, gettext("The client ID cannot be blank."))}
    else
      {:noreply, store_credentials(socket, client_id, client_secret)}
    end
  end

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("edit_credentials", _params, socket) do
    {:noreply, assign(socket, :credentials_editing?, true)}
  end

  def handle_event("edit_cover_key", _params, socket) do
    {:noreply, assign(socket, :cover_editing?, true)}
  end

  def handle_event("save_cover_key", %{"cover" => %{"steamgriddb_api_key" => key}}, socket) do
    key = String.trim(key)

    # A blank field means "leave what is stored alone", the same as the
    # Google secret above.
    if key != "" do
      Settings.put("steamgriddb_api_key", key)
    end

    {:noreply,
     socket
     |> assign_cover_form()
     |> put_flash(:info, gettext("Cover art settings saved."))}
  end

  def handle_event("save_language", %{"language" => %{"locale" => locale}}, socket) do
    cond do
      locale == "" -> Settings.clear_locale()
      locale in Gettext.known_locales(MnemoWeb.Gettext) -> Settings.put_locale(locale)
      true -> :ok
    end

    # A full redirect re-runs the locale plug, so the new language takes
    # effect immediately.
    {:noreply, redirect(socket, to: ~p"/settings")}
  end

  def handle_event("connect_drive", _params, socket) do
    case Drive.connect() do
      :ok ->
        {:noreply, socket}

      {:error, :not_configured} ->
        {:noreply, put_flash(socket, :error, gettext("Google OAuth client is not configured."))}
    end
  end

  def handle_event("disconnect_drive", _params, socket) do
    Drive.disconnect()
    {:noreply, assign(socket, drive: Drive.status())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1 class="text-lg font-semibold">{gettext("Settings")}</h1>

      <div id="drive-setup">
        <h2 class="font-semibold">{gettext("Google Drive")}</h2>
        <p class="text-sm opacity-70">
          {gettext(
            "Setting this up takes two steps, and both are needed: first you tell mnemo which Google app to use, then you authorize that app to reach your Drive."
          )}
        </p>
        <p class="text-sm opacity-70">
          {gettext(
            "You create the credentials once in your life and reuse the very same ones on every computer. The authorization in step 2 is what happens once per computer."
          )}
        </p>
      </div>

      <section class="card bg-base-200 p-6 space-y-4" id="google-credentials">
        <div class="flex items-start justify-between gap-3">
          <div>
            <h3 class="font-semibold">{gettext("Step 1 · Credentials")}</h3>
            <p class="text-sm opacity-70">
              {gettext(
                "mnemo connects to your Drive as a Google OAuth client of type \"Desktop app\". Paste its credentials here — the guide below shows how to create them for free."
              )}
            </p>
          </div>
          <span class={[
            "badge badge-soft whitespace-nowrap",
            if(@credentials_saved?, do: "badge-success", else: "badge-ghost")
          ]}>
            {if @credentials_saved?, do: gettext("Saved"), else: gettext("Pending")}
          </span>
        </div>

        <div
          class="rounded-box border border-success/30 bg-success/5 p-4 space-y-2"
          id="privacy-note"
        >
          <p class="flex items-center gap-2 text-sm font-medium">
            <.icon name="hero-lock-closed" class="size-4 shrink-0 text-success" />
            {gettext("mnemo only ever sees the folder it creates")}
          </p>
          <ul class="text-sm opacity-80 space-y-1.5 list-disc ml-6">
            <li>
              {gettext(
                "The permission requested covers only files this app itself created. The rest of your Drive — documents, photos, files from other apps — stays invisible to it. Google enforces that on their side; it is not a promise made by mnemo's code."
              )}
            </li>
            <li>
              {gettext("On the authorization screen Google words it like this:")}
              <em class="not-italic opacity-100">
                “{gettext(
                  "See, edit, create and delete only the specific Google Drive files you use with this app"
                )}”
              </em>
            </li>
            <li>
              {gettext(
                "The credentials are yours: they belong to a Google project in your own account and never leave this computer. mnemo has no server of its own, so nobody else — including whoever wrote it — can reach your saves."
              )}
            </li>
            <li>
              {gettext("You can revoke this access whenever you want.")}
              <.guide_link
                href="https://myaccount.google.com/permissions"
                label={gettext("your Google account permissions")}
              />
            </li>
          </ul>
        </div>

        <div
          :if={@credentials_saved? and not @credentials_editing?}
          id="credentials-saved-summary"
          class="flex flex-col gap-3 rounded-box border border-success/25 bg-success/5 p-4 sm:flex-row sm:items-center sm:justify-between"
        >
          <div class="flex items-center gap-3">
            <span class="flex size-9 shrink-0 items-center justify-center rounded-full bg-success/15 text-success">
              <.icon name="hero-check" class="size-5" />
            </span>
            <div>
              <p class="text-sm font-medium">{gettext("Google credentials are saved")}</p>
              <p class="text-xs opacity-65">
                {gettext("Keep using these credentials unless Google asks you to replace them.")}
              </p>
            </div>
          </div>
          <.button
            id="change-credentials"
            phx-click="edit_credentials"
            variant="secondary"
            class="btn btn-sm btn-ghost shrink-0"
          >
            <.icon name="hero-pencil-square" class="size-4" />
            {gettext("Change")}
          </.button>
        </div>

        <div :if={@credentials_editing?} id="credentials-editor" class="space-y-4">
          <details class="collapse collapse-arrow bg-base-300/40" id="oauth-guide">
            <summary class="collapse-title text-sm font-medium">
              {gettext("How to get these credentials, step by step")}
            </summary>
            <div class="collapse-content text-sm space-y-3">
              <p class="rounded-box bg-base-100/60 p-3 text-sm">
                <.icon name="hero-computer-desktop" class="size-4 mr-1 opacity-60" />
                {gettext(
                  "Already set mnemo up on another computer? Do not create anything new — import the same JSON file here, or paste the same two values, and go straight to step 2."
                )}
              </p>
              <ol class="list-decimal ml-5 space-y-2">
                <li>
                  {gettext(
                    "Open the Google Cloud console and sign in with the Google account whose Drive will hold your saves."
                  )}
                  <.guide_link
                    href="https://console.cloud.google.com"
                    label="console.cloud.google.com"
                  />
                </li>
                <li>
                  {gettext("Create a project. Any name works — \"mnemo\", for example.")}
                  <.guide_link href="https://console.cloud.google.com/projectcreate" />
                </li>
                <li>
                  {gettext("Enable the Google Drive API for that project.")}
                  <.guide_link href="https://console.cloud.google.com/apis/library/drive.googleapis.com" />
                </li>
                <li>
                  {gettext(
                    "Configure the consent screen under \"Google Auth Platform\": choose \"External\" and fill in the app name and your e-mail."
                  )}
                  <.guide_link href="https://console.cloud.google.com/auth/overview" />
                  <p class="text-xs opacity-70 mt-1">
                    {gettext(
                      "\"External\" only means a personal Google account instead of a Workspace organization. It does not publish anything, and it does not make your files public."
                    )}
                  </p>
                </li>
                <li>
                  {gettext(
                    "Publish the app to production under \"Audience\". While it stays in testing, Google drops the connection every 7 days."
                  )}
                  <.guide_link href="https://console.cloud.google.com/auth/audience" />
                </li>
                <li>
                  {gettext(
                    "Create an OAuth client under \"Clients\": application type \"Desktop app\"."
                  )}
                  <.guide_link href="https://console.cloud.google.com/auth/clients" />
                </li>
                <li>
                  {gettext(
                    "Download the client's JSON file and import it above. Keep that file somewhere safe and private — it is what you will reuse on your other computers."
                  )}
                </li>
              </ol>
              <p class="text-xs opacity-70">
                {gettext(
                  "Google will show an \"unverified app\" warning when you connect. That is expected: the app is yours, you created it minutes ago, and verification only exists for apps distributed to other people. Click \"Advanced\" and continue."
                )}
              </p>
            </div>
          </details>

          <form
            id="client-file-form"
            phx-change="validate_upload"
            phx-submit="validate_upload"
            phx-drop-target={@uploads.client_file.ref}
          >
            <label class="flex cursor-pointer flex-col items-center gap-2 rounded-box border-2 border-dashed border-base-300 p-6 text-center transition-colors hover:border-primary/50 hover:bg-base-300/30">
              <.icon name="hero-arrow-up-tray" class="size-6 opacity-60" />
              <span class="text-sm font-medium">
                {gettext("Import the JSON file downloaded from Google")}
              </span>
              <span class="text-xs opacity-70">
                {gettext(
                  "Drop the client_secret_….json file here, or click to pick it. mnemo reads the two keys out of it and keeps no copy of the file."
                )}
              </span>
              <.live_file_input upload={@uploads.client_file} class="sr-only" />
            </label>
            <p
              :for={err <- upload_errors(@uploads.client_file)}
              class="mt-2 text-xs text-error"
            >
              {upload_error_message(err)}
            </p>
            <p
              :for={entry <- @uploads.client_file.entries}
              :if={@uploads.client_file.entries != []}
              class="mt-2 text-xs text-error"
            >
              <span :for={err <- upload_errors(@uploads.client_file, entry)}>
                {upload_error_message(err)}
              </span>
            </p>
          </form>

          <div class="flex items-center gap-3 text-xs uppercase tracking-wide opacity-50">
            <span class="h-px flex-1 bg-base-300"></span>
            {gettext("or type them in")}
            <span class="h-px flex-1 bg-base-300"></span>
          </div>

          <.form
            for={@credentials_form}
            id="credentials-form"
            phx-submit="save_credentials"
            class="space-y-4"
          >
            <.input
              field={@credentials_form[:client_id]}
              type="text"
              label={gettext("Client ID")}
              placeholder="xxxxxxxx.apps.googleusercontent.com"
              autocomplete="off"
            />
            <.input
              field={@credentials_form[:client_secret]}
              type="password"
              label={gettext("Client secret")}
              placeholder={if @secret_set?, do: "••••••••••••", else: nil}
              autocomplete="off"
            />
            <p :if={@secret_set?} class="text-xs opacity-60">
              {gettext("A secret is already saved. Leave the field blank to keep it.")}
            </p>
            <.button variant="primary" id="save-credentials">
              {gettext("Save credentials")}
            </.button>
          </.form>
        </div>
      </section>

      <section class="card bg-base-200 p-6 space-y-4" id="drive-connection">
        <div class="flex items-start justify-between gap-3">
          <div>
            <h3 class="font-semibold">{gettext("Step 2 · Authorize access")}</h3>
            <p class="text-sm opacity-70">
              <%= if @credentials_saved? do %>
                {gettext(
                  "This opens your browser so Google can confirm that this computer may use the credentials from step 1."
                )}
              <% else %>
                {gettext(
                  "Finish step 1 first. Saving the credentials does not connect anything on its own — the authorization happens here."
                )}
              <% end %>
            </p>
          </div>
          <.connection_badge drive={@drive} />
        </div>
        <.drive_banner drive={@drive} />
        <.button
          :if={@drive.state == :connected}
          id="disconnect-drive"
          phx-click="disconnect_drive"
          data-confirm={gettext("Disconnect from Google Drive? Synced files stay in your Drive.")}
        >
          {gettext("Disconnect")}
        </.button>
      </section>

      <section class="card bg-base-200 p-6 space-y-4" id="cover-art">
        <div class="flex items-start justify-between gap-3">
          <div>
            <h2 class="font-semibold">{gettext("Cover art")}</h2>
            <p class="text-sm opacity-70">
              {gettext(
                "Covers come from the game itself: the artwork Steam already stored on this computer, or the icon in the install folder. For games from anywhere else, mnemo can look the cover up on SteamGridDB — paste a free API key to enable it."
              )}
            </p>
          </div>
          <span class={[
            "badge badge-soft whitespace-nowrap",
            if(@cover_key_set?, do: "badge-success", else: "badge-ghost")
          ]}>
            {if @cover_key_set?, do: gettext("Saved"), else: gettext("Pending")}
          </span>
        </div>

        <div
          :if={@cover_key_set? and not @cover_editing?}
          id="cover-key-saved-summary"
          class="flex flex-col gap-3 rounded-box border border-success/25 bg-success/5 p-4 sm:flex-row sm:items-center sm:justify-between"
        >
          <div class="flex items-center gap-3">
            <span class="flex size-9 shrink-0 items-center justify-center rounded-full bg-success/15 text-success">
              <.icon name="hero-check" class="size-5" />
            </span>
            <div>
              <p class="text-sm font-medium">{gettext("SteamGridDB key is saved")}</p>
              <p class="text-xs opacity-65">
                {gettext("External cover lookup is enabled for games without local artwork.")}
              </p>
            </div>
          </div>
          <.button
            id="change-cover-key"
            phx-click="edit_cover_key"
            variant="secondary"
            class="btn btn-sm btn-ghost shrink-0"
          >
            <.icon name="hero-pencil-square" class="size-4" />
            {gettext("Change")}
          </.button>
        </div>

        <.form
          :if={@cover_editing?}
          for={@cover_form}
          id="cover-form"
          phx-submit="save_cover_key"
          class="space-y-4"
        >
          <.input
            field={@cover_form[:steamgriddb_api_key]}
            type="password"
            label={gettext("SteamGridDB API key")}
            placeholder={if @cover_key_set?, do: "••••••••••••", else: gettext("optional")}
            autocomplete="off"
          />
          <p class="text-xs opacity-60">
            <a href="https://www.steamgriddb.com/profile/preferences/api" target="_blank" class="link">
              {gettext("Get a key")}
            </a>
            {gettext("— without one, games with no local artwork keep using a save screenshot.")}
          </p>
          <.button variant="primary" id="save-cover-key">{gettext("Save key")}</.button>
        </.form>
      </section>

      <section class="card bg-base-200 p-6 space-y-4" id="language-settings">
        <div>
          <h2 class="font-semibold">{gettext("Language")}</h2>
          <p class="text-sm opacity-70">
            {gettext("By default mnemo follows the system language.")}
          </p>
        </div>

        <.form for={@language_form} id="language-form" phx-change="save_language">
          <.input
            field={@language_form[:locale]}
            type="select"
            options={[
              {gettext("System default"), ""},
              {"English", "en"},
              {"Português (Brasil)", "pt_BR"}
            ]}
          />
        </.form>
      </section>
    </Layouts.app>
    """
  end
end
