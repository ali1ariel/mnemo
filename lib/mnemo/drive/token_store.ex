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
    dir = Path.dirname(path())
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    File.write!(path(), Jason.encode!(%{refresh_token: rt}))
    File.chmod!(path(), 0o600)
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
