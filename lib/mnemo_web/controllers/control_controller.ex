defmodule MnemoWeb.ControlController do
  use MnemoWeb, :controller

  alias Mnemo.Endpoint.Address

  def shutdown(conn, _params) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- Address.authorized?(token) do
      conn = send_resp(conn, 204, "")
      {:ok, _pid} = Task.Supervisor.start_child(Mnemo.TaskSupervisor, &shutdown/0)
      conn
    else
      _ -> send_resp(conn, 401, "")
    end
  end

  defp shutdown do
    case Application.get_env(:mnemo, :shutdown_callback) do
      nil -> System.stop(0)
      callback when is_function(callback, 0) -> callback.()
    end
  end
end
