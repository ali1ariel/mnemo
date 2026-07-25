defmodule Mnemo.Endpoint.AddressTest do
  use ExUnit.Case, async: false

  alias Mnemo.Endpoint.Address

  setup do
    dir = Path.join(System.tmp_dir!(), "mnemo-addr-#{System.unique_integer([:positive])}")
    file = Path.join([dir, "nested", "endpoint.json"])
    Application.put_env(:mnemo, :endpoint_address_file, file)

    on_exit(fn ->
      Application.delete_env(:mnemo, :endpoint_address_file)
      File.rm_rf!(dir)
    end)

    {:ok, address_file: file}
  end

  test "publishes the port the endpoint actually bound to", %{address_file: file} do
    start_supervised!(Address)

    assert {:ok, address} = Address.read(file)
    assert {:ok, {_ip, port}} = MnemoWeb.Endpoint.server_info(:http)
    assert address.port == port
    assert address.host == "127.0.0.1"
    assert address.os_pid == System.pid()
    assert is_binary(address.token)
    assert byte_size(address.token) >= 43
  end

  test "the address carries a url the launcher can open as it stands", %{address_file: file} do
    start_supervised!(Address)

    assert %{"url" => url, "port" => port} = file |> File.read!() |> Jason.decode!()
    assert url == "http://127.0.0.1:#{port}"
  end

  test "only authorizes the token published for this launch", %{address_file: file} do
    start_supervised!(Address)
    assert {:ok, %{token: token}} = Address.read(file)

    assert Address.authorized?(token)
    refute Address.authorized?("wrong-token")
  end

  test "creates the directory when it is not there yet", %{address_file: file} do
    refute File.exists?(Path.dirname(file))
    start_supervised!(Address)
    assert File.regular?(file)
  end

  # A file left behind would point a launcher at a port nothing is
  # listening on any more, or worse, at whatever took it over.
  test "removes the address on shutdown", %{address_file: file} do
    pid = start_supervised!(Address)
    assert File.regular?(file)

    :ok = stop_supervised(Address)
    refute Process.alive?(pid)
    refute File.exists?(file)
  end

  test "reports a file that is not a published address", %{address_file: file} do
    assert Address.read(file) == {:error, :enoent}

    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "not json")
    assert {:error, %Jason.DecodeError{}} = Address.read(file)

    File.write!(file, Jason.encode!(%{"host" => "127.0.0.1"}))
    assert Address.read(file) == {:error, :malformed}
  end
end
