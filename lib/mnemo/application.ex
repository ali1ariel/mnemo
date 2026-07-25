defmodule Mnemo.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        MnemoWeb.Telemetry,
        Mnemo.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:mnemo, :ecto_repos), skip: skip_migrations?()},
        {Phoenix.PubSub, name: Mnemo.PubSub},
        {Registry, keys: :unique, name: Mnemo.Game.Registry},
        {DynamicSupervisor, name: Mnemo.Game.Supervisor, strategy: :one_for_one},
        {Task.Supervisor, name: Mnemo.TaskSupervisor}
      ] ++
        fake_drive() ++
        [Mnemo.Drive] ++
        game_autostart() ++
        [MnemoWeb.Endpoint] ++
        endpoint_address()

    opts = [strategy: :one_for_one, name: Mnemo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MnemoWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp fake_drive do
    if Mnemo.Drive.Backend.impl() == Mnemo.Drive.Fake, do: [Mnemo.Drive.Fake], else: []
  end

  # After the endpoint, because it reports the port the endpoint actually
  # bound to. Only where something is listening: with `server: false` in
  # test there is no address to publish.
  defp endpoint_address do
    if Application.get_env(:mnemo, :publish_endpoint_address, false) do
      [Mnemo.Endpoint.Address]
    else
      []
    end
  end

  defp game_autostart do
    if Application.get_env(:mnemo, :autostart_games, true) do
      [{Task, &Mnemo.Game.start_all/0}]
    else
      []
    end
  end

  # Migrations run at boot in every environment except test (the test
  # alias migrates before the sandbox starts). Deleting the database file
  # and restarting must always come back up.
  defp skip_migrations?, do: Application.get_env(:mnemo, :skip_boot_migrations, false)
end
