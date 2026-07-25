defmodule Mnemo.Covers do
  @moduledoc """
  Cover art for a game, from the best source available.

  In order:

    1. art already downloaded for this game, kept in a local cache;
    2. the official Steam capsule, which Steam has already put in its own
       cache — accurate, offline, no key and no rate limit;
    3. the `icon.png` every packaged Ren'Py build ships;
    4. the screenshot inside the most recent save.

  A game that reaches step 4 with nothing better is also queued for a
  SteamGridDB lookup, which is the only source that covers titles nobody
  sells on Steam. That runs in the background and fills the cache for the
  next page load: a cover is never worth making someone wait for, and the
  screenshot is always there in the meantime.
  """

  require Logger

  alias Mnemo.Covers.External
  alias Mnemo.RenPy

  # Portrait capsule first: it is what a library grid wants. The wide
  # header is a reasonable second, and the logo has transparency that
  # looks wrong on a card.
  @steam_art ~w(library_600x900.jpg header.jpg library_hero.jpg)

  @doc """
  A game's image, as `{:ok, binary, content_type, :cover | :screenshot}`.

  `:none` means no source had anything — the caller decides what to draw
  in that hole.
  """
  def for_game(game) do
    case source_for(game) do
      {:cover, file} -> read(file, :cover)
      {:screenshot, save} -> read_screenshot(save)
      :none -> :none
    end
  end

  @doc """
  Where a game's image would come from, without reading it.

  The interface blurs save screenshots, which are arbitrary frames of a
  game and cannot be assumed safe to show, but published cover art is
  made to be looked at — so the two have to be told apart before
  rendering, not after.
  """
  def kind(game) do
    case source_for(game) do
      {kind, _} -> kind
      :none -> :none
    end
  end

  @doc """
  A cache key for the image currently selected for a game.

  Cover discovery is independent from save generations, so using the
  generation number in the image URL can leave a screenshot cached after
  better artwork becomes available.
  """
  def version(game) do
    case source_for(game) do
      {_kind, file} ->
        case File.stat(file, time: :posix) do
          {:ok, stat} -> :erlang.phash2({file, stat.size, stat.mtime})
          {:error, _} -> 0
        end

      :none ->
        0
    end
  end

  defp source_for(game) do
    with nil <- cached_file(game.id),
         nil <- install_art(game.install_path) do
      queue_lookup(game)

      case latest_save(RenPy.game_path(game)) do
        nil -> :none
        save -> {:screenshot, save}
      end
    else
      file -> {:cover, file}
    end
  end

  defp read(file, kind) do
    case File.read(file) do
      {:ok, bytes} -> {:ok, bytes, mime_for(file), kind}
      {:error, _} -> :none
    end
  end

  defp read_screenshot(save) do
    case RenPy.extract_screenshot(save) do
      {:ok, png} -> {:ok, png, "image/png", :screenshot}
      {:error, _} -> :none
    end
  end

  defp latest_save(nil), do: nil

  defp latest_save(path) do
    case RenPy.latest_save(path) do
      save when is_binary(save) -> save
      _ -> nil
    end
  end

  ## Downloaded art

  defp cached_file(game_id) do
    (cache_path(game_id) <> ".*")
    |> Path.wildcard()
    |> Enum.reject(&String.ends_with?(&1, ".miss"))
    |> List.first()
  end

  defp existing(path), do: if(File.regular?(path), do: path)

  @doc "Where downloaded art for a game is kept."
  def cache_dir do
    Application.get_env(:mnemo, :cover_cache_dir) ||
      Path.join(
        System.get_env("MNEMO_CACHE_DIR") || :filename.basedir(:user_cache, "mnemo"),
        "covers"
      )
  end

  defp cache_path(game_id), do: Path.join(cache_dir(), game_id)

  # A game with no art anywhere would otherwise hit the network on every
  # single page render, so a failed lookup leaves a marker behind.
  defp queue_lookup(game) do
    marker = cache_path(game.id) <> ".miss"

    cond do
      not external().configured?() -> :ok
      File.exists?(marker) -> :ok
      game.name in [nil, ""] -> :ok
      true -> start_lookup(game, marker)
    end
  end

  defp start_lookup(game, marker) do
    Task.Supervisor.start_child(Mnemo.TaskSupervisor, fn ->
      File.mkdir_p!(cache_dir())
      # Written up front so concurrent renders do not all fire a lookup.
      File.write!(marker, "")

      case external().fetch(game.name) do
        {:ok, bytes, type} ->
          File.write!(cache_path(game.id) <> extension_for(type), bytes)
          File.rm(marker)
          Logger.info("cover found for #{game.name}")

        :none ->
          :ok
      end
    end)

    :ok
  end

  @doc "Forget any downloaded art and any record of a failed lookup."
  def clear_cache(game_id) do
    for file <- Path.wildcard(cache_path(game_id) <> ".*"), do: File.rm(file)
    :ok
  end

  defp extension_for("image/png"), do: ".png"
  defp extension_for("image/webp"), do: ".webp"
  defp extension_for(_), do: ".jpg"

  @doc "The image for a folder found by the scan, before it is enrolled."
  def for_scan_entry(entry) do
    case install_art(entry[:install]) do
      nil ->
        case external_scan_cover(entry[:name]) do
          :none ->
            case latest_save(entry.path) do
              nil -> :none
              save -> read_screenshot(save)
            end

          cover ->
            cover
        end

      file ->
        read(file, :cover)
    end
  end

  defp external_scan_cover(name) when name in [nil, ""], do: :none

  defp external_scan_cover(name) do
    case cached_scan_file(name) do
      nil ->
        if external().configured?() do
          case external().fetch(name) do
            {:ok, bytes, type} ->
              File.mkdir_p!(cache_dir())
              File.write!(scan_cache_path(name) <> extension_for(type), bytes)
              {:ok, bytes, type, :cover}

            :none ->
              :none
          end
        else
          :none
        end

      file ->
        read(file, :cover)
    end
  end

  defp cached_scan_file(name) do
    (scan_cache_path(name) <> ".*")
    |> Path.wildcard()
    |> List.first()
  end

  defp scan_cache_path(name) do
    digest = :crypto.hash(:sha256, name) |> Base.url_encode64(padding: false)
    Path.join(cache_dir(), "scan-#{digest}")
  end

  defp external do
    Application.get_env(:mnemo, :cover_external, External)
  end

  defp install_art(nil), do: nil

  defp install_art(install_path) do
    steam_art(install_path) || existing(Path.join(install_path, "icon.png"))
  end

  ## Steam

  defp steam_art(install_path) do
    case steam_app_id(install_path) do
      {:ok, app_id} -> find_art(app_id)
      {:error, _} -> nil
    end
  end

  defp find_art(app_id) do
    for dir <- art_dirs(app_id), name <- @steam_art, reduce: nil do
      nil -> if File.regular?(Path.join(dir, name)), do: Path.join(dir, name)
      found -> found
    end
  end

  # Steam has moved this cache around between client versions, so both
  # the per-app folder and the flat naming are checked.
  defp art_dirs(app_id) do
    for root <- steam_roots() do
      Path.join([root, "appcache", "librarycache", app_id])
    end
  end

  @doc """
  The Steam application id owning an install directory.

  `appmanifest_<id>.acf` records the folder each app installed into, so
  matching on `installdir` maps a path back to its id without guessing
  from the name.
  """
  def steam_app_id(install_path) do
    install_dir = Path.basename(install_path)

    Enum.find_value(steam_roots(), {:error, :not_found}, fn root ->
      root
      |> Path.join("steamapps")
      |> Path.join("appmanifest_*.acf")
      |> Path.wildcard()
      |> Enum.find_value(fn manifest ->
        with {:ok, contents} <- File.read(manifest),
             ^install_dir <- acf_value(contents, "installdir"),
             app_id when is_binary(app_id) <- acf_value(contents, "appid") do
          {:ok, app_id}
        else
          _ -> nil
        end
      end)
    end)
  end

  defp acf_value(contents, key) do
    case Regex.run(~r/"#{key}"\s+"([^"]*)"/, contents, capture: :all_but_first) do
      [value] -> value
      _ -> nil
    end
  end

  defp steam_roots do
    case Application.get_env(:mnemo, :steam_roots) do
      nil ->
        ~w(~/.local/share/Steam ~/.steam/steam ~/Library/Application\ Support/Steam)
        |> Enum.map(&Path.expand/1)
        |> Enum.filter(&File.dir?/1)

      roots ->
        roots
    end
  end

  defp mime_for(path) do
    case Path.extname(path) do
      ".png" -> "image/png"
      _ -> "image/jpeg"
    end
  end
end
