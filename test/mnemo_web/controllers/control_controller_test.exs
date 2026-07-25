defmodule MnemoWeb.ControlControllerTest do
  use MnemoWeb.ConnCase, async: false

  alias Mnemo.Endpoint.Address

  setup do
    dir = Path.join(System.tmp_dir!(), "mnemo-control-#{System.unique_integer([:positive])}")
    file = Path.join(dir, "endpoint.json")
    test_pid = self()

    Application.put_env(:mnemo, :endpoint_address_file, file)
    Application.put_env(:mnemo, :shutdown_callback, fn -> send(test_pid, :shutdown) end)

    start_supervised!(Address)
    {:ok, address} = Address.read(file)

    on_exit(fn ->
      Application.delete_env(:mnemo, :endpoint_address_file)
      Application.delete_env(:mnemo, :shutdown_callback)
      File.rm_rf!(dir)
    end)

    {:ok, token: address.token}
  end

  test "rejects a shutdown without the launch token", %{conn: conn} do
    conn = post(conn, ~p"/_mnemo/shutdown")

    assert response(conn, 401)
    refute_receive :shutdown
  end

  test "accepts a bearer token and schedules a graceful shutdown", %{conn: conn, token: token} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> post(~p"/_mnemo/shutdown")

    assert response(conn, 204)
    assert_receive :shutdown
  end
end
