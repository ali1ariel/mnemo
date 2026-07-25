defmodule MnemoWeb.CoverController do
  use MnemoWeb, :controller

  alias Mnemo.{Games, RenPy}

  # A game's default cover is the screenshot inside its most recent save —
  # no external art API involved.
  def show(conn, %{"id" => id}) do
    with {:ok, _uuid} <- Ecto.UUID.cast(id),
         %{} = game <- Games.get(id),
         path when is_binary(path) <- RenPy.game_path(game),
         save when is_binary(save) <- RenPy.latest_save(path),
         {:ok, png} <- RenPy.extract_screenshot(save) do
      conn
      |> put_resp_content_type("image/png")
      |> put_resp_header("cache-control", "private, max-age=60")
      |> send_resp(200, png)
    else
      _ -> send_resp(conn, 404, "")
    end
  end
end
