defmodule MnemoWeb.DriveComponents do
  @moduledoc "Google Drive connection state, shared by the library and settings screens."

  use MnemoWeb, :html

  attr :drive, :map, required: true
  attr :settings_link, :boolean, default: false

  def drive_banner(assigns) do
    ~H"""
    <div id="drive-status" class="card bg-base-200 px-5 py-4">
      <%= case @drive.state do %>
        <% :connected -> %>
          <div class="flex items-center gap-2 text-sm">
            <span class="inline-block size-2 rounded-full bg-success"></span>
            {gettext("Connected to Google Drive")}
          </div>
        <% :not_configured -> %>
          <div class="flex items-center justify-between gap-4 text-sm">
            <div>
              <p class="font-medium">{gettext("Google OAuth client is not configured")}</p>
              <p class="opacity-70">{gettext("Add your Google credentials to start syncing.")}</p>
            </div>
            <.link
              :if={@settings_link}
              navigate={~p"/settings"}
              class="btn btn-primary"
              id="open-settings-link"
            >
              {gettext("Open Settings")}
            </.link>
          </div>
        <% :disconnected -> %>
          <div class="flex items-center justify-between gap-4 text-sm">
            <p>{gettext("Not connected to Google Drive.")}</p>
            <.button id="connect-drive" variant="primary" phx-click="connect_drive">
              {gettext("Connect Google Drive")}
            </.button>
          </div>
        <% :connecting -> %>
          <div class="flex items-center justify-between gap-4 text-sm">
            <p class="flex items-center gap-2">
              <.icon name="hero-arrow-path" class="size-4 motion-safe:animate-spin" />
              {gettext("Waiting for authorization in the browser…")}
            </p>
            <a
              :if={@drive.auth_url}
              href={@drive.auth_url}
              target="_blank"
              class="link"
              id="auth-url-fallback"
            >
              {gettext("Browser did not open? Click here.")}
            </a>
          </div>
        <% :reconnect_required -> %>
          <div class="flex items-center justify-between gap-4 text-sm">
            <p class="text-warning">
              {gettext("The Google Drive session expired. Reconnect to resume syncing.")}
            </p>
            <.button id="reconnect-drive" variant="primary" phx-click="connect_drive">
              {gettext("Reconnect account")}
            </.button>
          </div>
      <% end %>
    </div>
    """
  end
end
