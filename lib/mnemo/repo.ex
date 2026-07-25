defmodule Mnemo.Repo do
  use Ecto.Repo,
    otp_app: :mnemo,
    adapter: Ecto.Adapters.SQLite3
end
