defmodule MnemoWeb.SettingsLive do
  use MnemoWeb, :live_view

  import MnemoWeb.DriveComponents

  alias Mnemo.{Drive, Settings}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Drive.subscribe()

    {:ok,
     socket
     |> assign(page_title: gettext("Settings"))
     |> assign(drive: Drive.status())
     |> assign_credentials_form()
     |> assign_language_form()}
  end

  defp assign_credentials_form(socket) do
    client = Drive.resolve_client()

    socket
    |> assign(:secret_set?, client != nil and client.client_secret != nil)
    |> assign(
      :credentials_form,
      to_form(%{"client_id" => (client && client.client_id) || "", "client_secret" => ""},
        as: :credentials
      )
    )
  end

  defp assign_language_form(socket) do
    assign(
      socket,
      :language_form,
      to_form(%{"locale" => Settings.locale() || ""}, as: :language)
    )
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
      Settings.put_google_client_id(client_id)

      if client_secret != "" do
        Settings.put_google_client_secret(client_secret)
      end

      Drive.reload_client()

      {:noreply,
       socket
       |> assign(drive: Drive.status())
       |> assign_credentials_form()
       |> put_flash(:info, gettext("Credentials saved."))}
    end
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

      <section class="card bg-base-200 p-6 space-y-4" id="google-credentials">
        <div>
          <h2 class="font-semibold">{gettext("Google credentials")}</h2>
          <p class="text-sm opacity-70">
            {gettext(
              "mnemo connects to your Drive as a Google OAuth client of type \"Desktop app\". Create one in the Google Cloud console and paste its credentials here — the README has the step by step."
            )}
          </p>
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
      </section>

      <section class="space-y-3" id="drive-connection">
        <h2 class="font-semibold">{gettext("Connection")}</h2>
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
