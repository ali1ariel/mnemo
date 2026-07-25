import Config

config :mnemo, :drive_backend, Mnemo.Drive.Fake
config :mnemo, :autostart_games, false
config :mnemo, :skip_boot_migrations, true
config :mnemo, :renpy_roots, []
config :mnemo, :install_dirs, []

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :mnemo, Mnemo.Repo,
  database: Path.expand("../mnemo_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# The server runs on port 0, the same as production does. Tests reach the
# router directly and do not need the socket, but `Mnemo.Endpoint.Address`
# reports what the endpoint bound to, and there is no honest way to test
# that against an endpoint that never bound anything. Port 0 means the
# suite cannot collide with whatever else is listening on this machine.
config :mnemo, MnemoWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 0],
  secret_key_base: "x0+l+0eF8dEWehQ5HOgoWZOucoJtMa8N4Ctat6yVp0/q25rgs1DaIbhmDJvQ2qHV",
  server: true

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
