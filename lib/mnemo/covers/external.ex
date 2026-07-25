defmodule Mnemo.Covers.External do
  @moduledoc """
  Looking up cover art on SteamGridDB.

  It is the one source that covers games nobody sells on Steam — itch.io
  releases, doujin builds, anything downloaded as a zip — because its
  whole reason to exist is custom art for non-Steam library entries.

  A free API key is required and lives in settings. Without one, the
  lookup is skipped rather than failing: local art and the save
  screenshot still work, so the interface never depends on this.
  """

  require Logger

  @base "https://www.steamgriddb.com/api/v2"
  # Portrait, matching what the library grid draws.
  @dimensions "600x900"
  @timeout 15_000

  @doc "Find cover bytes for a game title, or `:none`."
  def fetch(name) when is_binary(name) do
    case api_key() do
      nil ->
        :none

      key ->
        with {:ok, id} <- search(name, key),
             {:ok, url} <- grid_url(id, key),
             {:ok, bytes, type} <- download(url) do
          {:ok, bytes, type}
        else
          {:error, reason} ->
            Logger.info("cover lookup for #{inspect(name)} failed: #{inspect(reason)}")
            :none

          :none ->
            :none
        end
    end
  end

  def configured?, do: api_key() != nil

  defp api_key do
    case Mnemo.Settings.get("steamgriddb_api_key") do
      nil -> nil
      "" -> nil
      key -> String.trim(key)
    end
  end

  defp search(name, key) do
    case request("/search/autocomplete/#{URI.encode(name)}", key) do
      {:ok, %{"data" => [%{"id" => id} | _]}} -> {:ok, id}
      {:ok, %{"data" => []}} -> :none
      {:ok, _} -> :none
      error -> error
    end
  end

  defp grid_url(id, key) do
    case request("/grids/game/#{id}?dimensions=#{@dimensions}", key) do
      {:ok, %{"data" => [%{"url" => url} | _]}} -> {:ok, url}
      {:ok, %{"data" => []}} -> :none
      {:ok, _} -> :none
      error -> error
    end
  end

  defp request(path, key) do
    case Req.get(@base <> path,
           auth: {:bearer, key},
           receive_timeout: @timeout,
           retry: :transient,
           max_retries: 2
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end

  defp download(url) do
    case Req.get(url, receive_timeout: @timeout, decode_body: false, retry: :transient) do
      {:ok, %{status: 200, body: bytes}} when is_binary(bytes) ->
        {:ok, bytes, content_type(url)}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp content_type(url) do
    case url |> URI.parse() |> Map.get(:path, "") |> Path.extname() do
      ".png" -> "image/png"
      ".webp" -> "image/webp"
      _ -> "image/jpeg"
    end
  end
end
