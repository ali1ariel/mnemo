defmodule Mnemo.DriveTest do
  use Mnemo.DataCase, async: false

  alias Mnemo.Drive.TokenStore
  alias Mnemo.{Drive, Settings}

  setup do
    original_backend = Application.get_env(:mnemo, :drive_backend)
    original_client = Application.get_env(:mnemo, Drive)

    token_dir =
      Path.join(System.tmp_dir!(), "mnemo-token-#{System.unique_integer([:positive])}")

    Application.put_env(:mnemo, :drive_backend, Mnemo.Drive.HTTP)
    Application.put_env(:mnemo, :token_path, Path.join(token_dir, "google_token.json"))
    Application.put_env(:mnemo, Drive, client_id: nil, client_secret: nil)

    on_exit(fn ->
      Application.put_env(:mnemo, :drive_backend, original_backend)
      Application.put_env(:mnemo, Drive, original_client || [])
      Application.delete_env(:mnemo, :token_path)
      File.rm_rf!(token_dir)
    end)

    :ok
  end

  defp start_drive! do
    start_supervised!(%{id: make_ref(), start: {GenServer, :start_link, [Drive, :ok]}})
  end

  defp status(pid), do: GenServer.call(pid, :status)

  test "without credentials anywhere the status is not_configured" do
    pid = start_drive!()
    assert %{state: :not_configured, client_id: nil} = status(pid)
  end

  test "environment credentials are the fallback" do
    Application.put_env(:mnemo, Drive, client_id: "env-id", client_secret: "env-secret")
    pid = start_drive!()
    assert %{state: :disconnected, client_id: "env-id"} = status(pid)
  end

  test "credentials saved in settings win over the environment" do
    Application.put_env(:mnemo, Drive, client_id: "env-id", client_secret: "env-secret")
    Settings.put_google_client_id("db-id")
    Settings.put_google_client_secret("db-secret")

    pid = start_drive!()
    assert %{state: :disconnected, client_id: "db-id"} = status(pid)
  end

  test "a stored refresh token connects at boot" do
    Settings.put_google_client_id("db-id")
    Settings.put_google_client_secret("db-secret")
    TokenStore.save(%{refresh_token: "stored-token"})

    pid = start_drive!()
    assert %{state: :connected} = status(pid)
  end

  test "reload after the first credential save enables connecting" do
    pid = start_drive!()
    assert %{state: :not_configured} = status(pid)

    Settings.put_google_client_id("db-id")
    Settings.put_google_client_secret("db-secret")
    assert GenServer.call(pid, :reload_client) == :ok

    assert %{state: :disconnected, client_id: "db-id"} = status(pid)
  end

  test "changing the client id clears the stored session" do
    Settings.put_google_client_id("old-id")
    Settings.put_google_client_secret("old-secret")
    TokenStore.save(%{refresh_token: "stored-token"})

    pid = start_drive!()
    assert %{state: :connected} = status(pid)

    Settings.put_google_client_id("new-id")
    GenServer.call(pid, :reload_client)

    assert %{state: :disconnected, client_id: "new-id"} = status(pid)
    assert TokenStore.load() == :error
  end

  test "re-saving the same client id keeps the session" do
    Settings.put_google_client_id("same-id")
    Settings.put_google_client_secret("old-secret")
    TokenStore.save(%{refresh_token: "stored-token"})

    pid = start_drive!()
    assert %{state: :connected} = status(pid)

    Settings.put_google_client_secret("rotated-secret")
    GenServer.call(pid, :reload_client)

    assert %{state: :connected, client_id: "same-id"} = status(pid)
    assert {:ok, %{refresh_token: "stored-token"}} = TokenStore.load()
  end
end
