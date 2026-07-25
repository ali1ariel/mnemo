defmodule Mnemo.Drive.TokenStore do
  @moduledoc """
  Refresh token on disk with `0600` permissions.

  A keyring would protect against other users on the machine, not against
  code running as this user — not worth three external binaries.
  """

  def load do
    with {:ok, raw} <- File.read(path()),
         {:ok, %{"refresh_token" => rt}} when is_binary(rt) <- Jason.decode(raw) do
      {:ok, %{refresh_token: rt}}
    else
      _ -> :error
    end
  end

  def save(%{refresh_token: rt}) when is_binary(rt) do
    file = path()
    File.mkdir_p!(Path.dirname(file))

    # The default config dir is ours to lock down; the parent of a custom
    # :token_path is not.
    if Application.get_env(:mnemo, :token_path) == nil do
      File.chmod!(Path.dirname(file), 0o700)
    end

    File.write!(file, Jason.encode!(%{refresh_token: rt}))
    File.chmod!(file, 0o600)
    :ok
  end

  def clear do
    File.rm(path())
    :ok
  end

  def path do
    Application.get_env(:mnemo, :token_path) ||
      Path.join(:filename.basedir(:user_config, "mnemo"), "google_token.json")
  end
end
