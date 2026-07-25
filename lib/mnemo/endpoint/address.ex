defmodule Mnemo.Endpoint.Address do
  @moduledoc """
  Write down where the endpoint ended up listening.

  The endpoint binds to port 0 so the operating system hands out a free
  one, which is the only way to guarantee an application someone
  double-clicked will start: a fixed port fails the moment anything else
  holds it, and there is nowhere to show that error before the window
  exists.

  The consequence is that nothing outside the BEAM can know the address
  ahead of time, so it is written to a file the launcher reads. A file
  rather than distribution: `bin/mnemo rpc` needs a named node and epmd,
  which an embedded runtime may not have, whereas the file works for any
  launcher that can read JSON.

  The file is removed on shutdown, so a stale address never outlives the
  process that owned it. It also carries the OS pid, which is what lets a
  launcher tell "the app is running" from "the app died without cleaning
  up".
  """

  use GenServer, restart: :transient

  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Where the address is published.

  Under the user data directory, next to the database — this is machine
  state, not configuration.
  """
  def path do
    Application.get_env(:mnemo, :endpoint_address_file) ||
      Path.join(:filename.basedir(:user_data, "mnemo"), "endpoint.json")
  end

  @doc "Read a published address, for tests and for tooling."
  def read(file \\ path()) do
    with {:ok, raw} <- File.read(file),
         {:ok, %{"port" => port} = info} when is_integer(port) <- Jason.decode(raw) do
      {:ok, %{host: info["host"], port: port, os_pid: info["os_pid"]}}
    else
      {:ok, _malformed} -> {:error, :malformed}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    case publish() do
      :ok ->
        {:ok, %{}}

      {:error, reason} ->
        # Losing the address file does not stop the application from
        # working, only from being found, so this is logged rather than
        # brought down: a supervisor restart would not fix a read-only
        # directory.
        Logger.warning("could not publish the endpoint address: #{inspect(reason)}")
        {:ok, %{}}
    end
  end

  defp publish do
    with {:ok, {ip, port}} <- MnemoWeb.Endpoint.server_info(:http),
         file = path(),
         :ok <- File.mkdir_p(Path.dirname(file)) do
      contents =
        Jason.encode!(%{
          host: ip |> :inet.ntoa() |> to_string(),
          port: port,
          os_pid: System.pid(),
          url: "http://#{format_host(ip)}:#{port}"
        })

      File.write(file, contents)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # IPv6 literals need brackets to be a valid URL authority.
  defp format_host(ip) when tuple_size(ip) == 8, do: "[#{ip |> :inet.ntoa() |> to_string()}]"
  defp format_host(ip), do: ip |> :inet.ntoa() |> to_string()

  @impl true
  def terminate(_reason, _state) do
    File.rm(path())
    :ok
  end
end
