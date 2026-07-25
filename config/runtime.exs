import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/mnemo start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :mnemo, MnemoWeb.Endpoint, server: true
end

config :mnemo, Mnemo.Drive,
  client_id: System.get_env("MNEMO_GOOGLE_CLIENT_ID"),
  client_secret: System.get_env("MNEMO_GOOGLE_CLIENT_SECRET")

if System.get_env("MNEMO_FAKE_DRIVE") do
  config :mnemo, :drive_backend, Mnemo.Drive.Fake
end

if config_env() == :prod do
  # The app dir is read-only inside macOS .app bundles and AppImages,
  # so the database lives in the per-user data directory.
  database_path =
    System.get_env("DATABASE_PATH") ||
      Path.join(:filename.basedir(:user_data, "mnemo"), "mnemo.db")

  File.mkdir_p!(Path.dirname(database_path))

  config :mnemo, Mnemo.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      Base.encode64(:crypto.strong_rand_bytes(48))

  config :mnemo, MnemoWeb.Endpoint,
    # This must match the literal host published in endpoint.json. Phoenix
    # validates the LiveView WebSocket Origin against this host in production.
    url: [host: "127.0.0.1"],
    http: [
      # Loopback only: this is a local desktop app, and binding to
      # loopback does not trigger the Windows Firewall prompt.
      ip: {127, 0, 0, 1},
      # Port 0 lets the OS pick a free one. A fixed port refuses to start
      # whenever anything else already holds it, which for something
      # someone double-clicked is a failure with no explanation. The port
      # actually bound is published by `Mnemo.Endpoint.Address` for the
      # window that has to load the interface.
      port: String.to_integer(System.get_env("PORT") || "0")
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :mnemo, MnemoWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :mnemo, MnemoWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end

# An explicit PORT wins everywhere, including over the fixed ports dev
# and test配 use.
if port = System.get_env("PORT") do
  config :mnemo, MnemoWeb.Endpoint, http: [port: String.to_integer(port)]
end
