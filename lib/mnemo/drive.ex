defmodule Mnemo.Drive do
  @moduledoc """
  Connection state for the Google account: token cache, refresh, and the
  interactive connect flow.

  `invalid_grant` is an explicit `:reconnect_required` state surfaced in
  the interface — never a stacktrace. It happens in normal life: testing
  apps expire tokens in 7 days, 6 months of disuse invalidates them, and
  the 100-token-per-client cap silently drops the oldest.
  """

  use GenServer

  require Logger

  alias Mnemo.Drive.{Auth, Backend, TokenStore}

  @topic "drive"
  # Refresh slightly early so a token never expires mid-upload.
  @expiry_margin_s 60

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(Mnemo.PubSub, @topic)

  @doc "UI-facing summary: `%{state: ..., auth_url: ..., last_error: ...}`."
  def status, do: GenServer.call(__MODULE__, :status)

  def connected?, do: status().state == :connected

  @doc "Start the interactive OAuth flow (opens the browser)."
  def connect, do: GenServer.call(__MODULE__, :connect)

  def disconnect, do: GenServer.call(__MODULE__, :disconnect)

  @doc "A valid access token, refreshing if needed. Called by the HTTP backend."
  def access_token, do: GenServer.call(__MODULE__, :access_token, 60_000)

  ## Server

  @impl true
  def init(:ok) do
    state = %{
      client: load_client(),
      refresh_token: nil,
      access_token: nil,
      expires_at: nil,
      status: :disconnected,
      auth_url: nil,
      auth_task: nil,
      last_error: nil
    }

    state =
      cond do
        Backend.impl() != Mnemo.Drive.HTTP ->
          %{state | status: :connected}

        state.client == nil ->
          %{state | status: :not_configured}

        true ->
          case TokenStore.load() do
            {:ok, %{refresh_token: rt}} -> %{state | refresh_token: rt, status: :connected}
            :error -> %{state | status: :disconnected}
          end
      end

    {:ok, state}
  end

  defp load_client do
    config = Application.get_env(:mnemo, __MODULE__, [])
    client_id = config[:client_id]
    client_secret = config[:client_secret]

    if is_binary(client_id) and client_id != "" do
      %{client_id: client_id, client_secret: client_secret}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  def handle_call(:connect, _from, %{client: nil} = state) do
    {:reply, {:error, :not_configured}, state}
  end

  def handle_call(:connect, _from, %{auth_task: task} = state) when task != nil do
    {:reply, :ok, state}
  end

  def handle_call(:connect, _from, state) do
    server = self()

    task =
      Task.Supervisor.async_nolink(Mnemo.TaskSupervisor, fn ->
        Auth.run(state.client, fn url -> send(server, {:auth_url, url}) end)
      end)

    state = %{state | status: :connecting, auth_task: task.ref, last_error: nil}
    broadcast(state)
    {:reply, :ok, state}
  end

  def handle_call(:disconnect, _from, state) do
    TokenStore.clear()

    state = %{
      state
      | refresh_token: nil,
        access_token: nil,
        expires_at: nil,
        status: if(state.client, do: :disconnected, else: :not_configured),
        auth_url: nil
    }

    broadcast(state)
    {:reply, :ok, state}
  end

  def handle_call(:access_token, _from, state) do
    cond do
      Backend.impl() != Mnemo.Drive.HTTP ->
        {:reply, {:ok, "fake-token"}, state}

      valid_token?(state) ->
        {:reply, {:ok, state.access_token}, state}

      state.refresh_token != nil ->
        refresh(state)

      true ->
        {:reply, {:error, state.status}, state}
    end
  end

  defp valid_token?(%{access_token: token, expires_at: expires_at}) do
    token != nil and expires_at != nil and
      DateTime.diff(expires_at, DateTime.utc_now()) > @expiry_margin_s
  end

  defp refresh(state) do
    case Auth.refresh(state.client, state.refresh_token) do
      {:ok, tokens} ->
        state = store_tokens(state, tokens)
        {:reply, {:ok, state.access_token}, state}

      {:error, {:invalid_grant, _}} ->
        state = %{state | status: :reconnect_required, access_token: nil, expires_at: nil}
        broadcast(state)
        {:reply, {:error, :reconnect_required}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:auth_url, url}, state) do
    state = %{state | auth_url: url}
    broadcast(state)
    {:noreply, state}
  end

  def handle_info({ref, result}, %{auth_task: ref} = state) do
    Process.demonitor(ref, [:flush])

    state =
      case result do
        {:ok, %{refresh_token: rt} = tokens} when is_binary(rt) ->
          TokenStore.save(%{refresh_token: rt})
          store_tokens(%{state | refresh_token: rt}, tokens)

        {:ok, _tokens_without_refresh} ->
          %{state | status: :disconnected, last_error: :no_refresh_token}

        {:error, reason} ->
          Logger.warning("drive connect failed: #{inspect(reason)}")
          %{state | status: after_failure_status(state), last_error: reason}
      end

    state = %{state | auth_task: nil, auth_url: nil}
    broadcast(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{auth_task: ref} = state) do
    state = %{
      state
      | auth_task: nil,
        auth_url: nil,
        status: after_failure_status(state),
        last_error: {:crashed, reason}
    }

    broadcast(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp store_tokens(state, tokens) do
    expires_at = DateTime.add(DateTime.utc_now(), tokens.expires_in, :second)

    %{
      state
      | access_token: tokens.access_token,
        expires_at: expires_at,
        status: :connected,
        last_error: nil
    }
  end

  defp after_failure_status(%{refresh_token: rt}) when is_binary(rt), do: :connected
  defp after_failure_status(_state), do: :disconnected

  defp public_status(state) do
    %{state: state.status, auth_url: state.auth_url, last_error: state.last_error}
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(Mnemo.PubSub, @topic, {:drive, public_status(state)})
  end
end
