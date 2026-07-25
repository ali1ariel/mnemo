defmodule MnemoWeb.Router do
  use MnemoWeb, :router

  scope "/_mnemo", MnemoWeb do
    post "/shutdown", ControlController, :shutdown
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MnemoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug MnemoWeb.Plugs.Locale
  end

  scope "/", MnemoWeb do
    pipe_through :browser

    live_session :default, on_mount: MnemoWeb.LocaleHook do
      live "/", LibraryLive
      live "/enroll", EnrollLive
      live "/games/:id", SlotsLive
      live "/settings", SettingsLive
    end

    get "/covers/:id", CoverController, :show
    get "/covers/:id/:file", CoverController, :slot
    get "/scan/preview", CoverController, :scan_preview
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:mnemo, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: MnemoWeb.Telemetry
    end
  end
end
