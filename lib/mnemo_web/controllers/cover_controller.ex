defmodule MnemoWeb.CoverController do
  use MnemoWeb, :controller

  alias Mnemo.{Covers, Games, RenPy}

  def show(conn, %{"id" => id}) do
    with {:ok, _uuid} <- Ecto.UUID.cast(id),
         %{} = game <- Games.get(id),
         {:ok, bytes, type, _kind} <- Covers.for_game(game) do
      send_image(conn, bytes, type, "private, max-age=60")
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  def slot(conn, %{"id" => id, "file" => file}) do
    with {:ok, _uuid} <- Ecto.UUID.cast(id),
         %{} = game <- Games.get(id),
         # The file name comes from the URL: it must be a bare slot file
         # name, never a path.
         true <- file == Path.basename(file),
         slot when slot not in [:other, :persistent] <- RenPy.parse_slot(file),
         path when is_binary(path) <- RenPy.game_path(game),
         {:ok, png} <- RenPy.extract_screenshot(Path.join(path, file)) do
      send_png(conn, png, "private, max-age=86400")
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  # Slot screenshots for scanned-but-not-enrolled games. Everything here
  # comes from the URL, so each component is pinned: the root must be one
  # of the known Ren'Py roots, and dir/file must be bare names.
  def scan_preview(conn, %{"root" => root, "dir" => dir, "file" => file}) do
    with true <- root in RenPy.roots(),
         true <- bare_name?(dir),
         true <- bare_name?(file),
         slot when slot not in [:other, :persistent] <- RenPy.parse_slot(file),
         {:ok, png} <- RenPy.extract_screenshot(Path.join([root, dir, file])) do
      send_png(conn, png, "private, max-age=300")
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  def scan_preview(conn, _params), do: send_resp(conn, 404, "")

  defp bare_name?(name) do
    name not in ["", ".", ".."] and name == Path.basename(name)
  end

  defp send_png(conn, png, cache_control), do: send_image(conn, png, "image/png", cache_control)

  defp send_image(conn, bytes, type, cache_control) do
    conn
    |> put_resp_content_type(type)
    |> put_resp_header("cache-control", cache_control)
    |> send_resp(200, bytes)
  end
end
