defmodule Mnemo.Drive.Remote do
  @moduledoc """
  The `/mnemo` layout in Drive:

      /mnemo/
      ├── devices.json
      └── games/<game_uuid>/
          ├── game.json
          ├── generations/000001.json   # append-only, never overwritten
          └── blobs/<sha256>

  Manifests being append-only is what gives race detection without a
  distributed lock: two devices writing the same generation number produce
  two files with the same name, which is the signature of a fork.
  """

  alias Mnemo.Settings

  @root_name "mnemo"
  @json_mime "application/json"

  def root_name, do: @root_name
  @blob_mime "application/octet-stream"
  @manifest_re ~r/^(\d{6})\.json$/

  def ensure_layout(backend) do
    with {:ok, root} <- find_or_create_folder(backend, "root", @root_name),
         {:ok, games} <- find_or_create_folder(backend, root.id, "games"),
         :ok <- register_device(backend, root.id) do
      {:ok, %{root_id: root.id, games_id: games.id}}
    end
  end

  @doc """
  Locate this game's remote folder, adopting an existing one when another
  install already enrolled the same `save_directory`, or create it.
  """
  def ensure_game(backend, games_id, game) do
    with {:ok, folder_id} <- locate_game(backend, games_id, game) do
      case folder_id do
        nil -> create_game(backend, games_id, game)
        id -> load_game_folder(backend, id, game)
      end
    end
  end

  defp locate_game(_backend, _games_id, %{remote_folder_id: id}) when is_binary(id) do
    {:ok, id}
  end

  defp locate_game(backend, games_id, game) do
    # Folder names are a fast path only — `game.id` covers folders written
    # before names were readable, and a folder the user renamed in Drive
    # still resolves through the game.json scan below.
    with {:ok, nil} <- find_named_folder(backend, games_id, folder_name(game)),
         {:ok, nil} <- find_named_folder(backend, games_id, game.id) do
      find_by_save_directory(backend, games_id, game.save_directory)
    end
  end

  defp find_named_folder(backend, games_id, name) do
    case backend.find_child(games_id, name) do
      {:ok, %{folder?: true} = folder} -> {:ok, folder.id}
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  # Drive treats "/" as a path separator in some clients; nothing else in a
  # Ren'Py save_directory needs escaping.
  defp folder_name(game), do: String.replace(game.save_directory, ~r"[/\\]", "_")

  # game.json carries the save_directory, which is what lets another
  # machine match its local folder to this remote game on its own.
  defp find_by_save_directory(backend, games_id, save_directory) do
    with {:ok, children} <- backend.list_children(games_id) do
      children
      |> Enum.filter(& &1.folder?)
      |> Enum.reduce_while({:ok, nil}, fn folder, acc ->
        case read_game_json(backend, folder.id) do
          {:ok, %{"save_directory" => ^save_directory}} -> {:halt, {:ok, folder.id}}
          {:ok, _other} -> {:cont, acc}
          {:error, _} -> {:cont, acc}
        end
      end)
    end
  end

  defp read_game_json(backend, folder_id) do
    with {:ok, %{} = meta} <- backend.find_child(folder_id, "game.json"),
         {:ok, raw} <- backend.download(meta.id) do
      Jason.decode(raw)
    else
      {:ok, nil} -> {:error, :no_game_json}
      error -> error
    end
  end

  defp create_game(backend, games_id, game) do
    with {:ok, folder} <- backend.create_folder(games_id, folder_name(game)) do
      load_game_folder(backend, folder.id, game)
    end
  end

  # Every step here is idempotent, so a run that died partway through
  # creation is repaired by the next one instead of leaving a folder that
  # is missing its identity file forever.
  defp load_game_folder(backend, folder_id, game) do
    with {:ok, generations} <- find_or_create_folder(backend, folder_id, "generations"),
         {:ok, blobs} <- find_or_create_folder(backend, folder_id, "blobs"),
         :ok <- sync_game_json(backend, folder_id, game) do
      {:ok, %{folder_id: folder_id, generations_id: generations.id, blobs_id: blobs.id}}
    end
  end

  defp sync_game_json(backend, folder_id, game) do
    case backend.find_child(folder_id, "game.json") do
      {:ok, nil} ->
        write_game_json(backend, folder_id, merge_game(%{}, game))

      {:ok, meta} ->
        with {:ok, raw} <- backend.download(meta.id) do
          current = decode_game_json(raw)
          desired = merge_game(current, game)

          if desired == current do
            :ok
          else
            with {:ok, _} <- backend.update(meta.id, Jason.encode!(desired), @json_mime), do: :ok
          end
        end

      error ->
        error
    end
  end

  defp write_game_json(backend, folder_id, doc) do
    with {:ok, _} <- backend.upload(folder_id, "game.json", Jason.encode!(doc), @json_mime),
         do: :ok
  end

  defp decode_game_json(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = doc} -> doc
      _ -> %{}
    end
  end

  # The name is shared metadata, but a machine that has not named the game
  # locally must never blank out a name another machine set.
  defp merge_game(current, game) do
    current
    |> Map.put_new("id", game.id)
    |> Map.put("save_directory", game.save_directory)
    |> Map.put_new("created_by_device", Settings.device_id())
    |> Map.put_new("created_at", DateTime.to_iso8601(DateTime.utc_now(:second)))
    |> then(fn doc -> if game.name, do: Map.put(doc, "name", game.name), else: doc end)
  end

  @doc "Every manifest number present remotely, duplicates preserved — a duplicate is a fork."
  def list_generation_numbers(backend, generations_id) do
    with {:ok, children} <- backend.list_children(generations_id) do
      numbers =
        for %{folder?: false, name: name} <- children,
            captures = Regex.run(@manifest_re, name),
            captures != nil,
            do: String.to_integer(Enum.at(captures, 1))

      {:ok, Enum.sort(numbers)}
    end
  end

  def put_manifest(backend, generations_id, number, manifest) when is_map(manifest) do
    backend.upload(generations_id, manifest_name(number), Jason.encode!(manifest), @json_mime)
  end

  def get_manifest(backend, generations_id, number) do
    case backend.find_child(generations_id, manifest_name(number)) do
      {:ok, nil} ->
        {:error, {:manifest_not_found, number}}

      {:ok, meta} ->
        with {:ok, raw} <- backend.download(meta.id), do: Jason.decode(raw)

      error ->
        error
    end
  end

  defp manifest_name(number), do: String.pad_leading(Integer.to_string(number), 6, "0") <> ".json"

  @doc "Upload a blob unless it is already present; returns `:uploaded` or `:existed`."
  def upload_blob(backend, blobs_id, sha256, content) do
    case backend.find_child(blobs_id, sha256) do
      {:ok, nil} ->
        with {:ok, meta} <- backend.upload(blobs_id, sha256, content, @blob_mime) do
          {:ok, meta, :uploaded}
        end

      {:ok, meta} ->
        {:ok, meta, :existed}

      error ->
        error
    end
  end

  defp find_or_create_folder(backend, parent_id, name) do
    case backend.find_child(parent_id, name) do
      {:ok, nil} -> backend.create_folder(parent_id, name)
      {:ok, meta} -> {:ok, meta}
      error -> error
    end
  end

  defp register_device(backend, root_id) do
    device_id = Settings.device_id()

    case backend.find_child(root_id, "devices.json") do
      {:ok, nil} ->
        doc = Jason.encode!(%{"devices" => [device_entry(device_id)]})

        with {:ok, _} <- backend.upload(root_id, "devices.json", doc, @json_mime), do: :ok

      {:ok, meta} ->
        with {:ok, raw} <- backend.download(meta.id),
             {:ok, doc} <- Jason.decode(raw) do
          devices = doc["devices"] || []

          if Enum.any?(devices, &(&1["id"] == device_id)) do
            :ok
          else
            updated = Jason.encode!(%{doc | "devices" => devices ++ [device_entry(device_id)]})

            with {:ok, _} <- backend.update(meta.id, updated, @json_mime), do: :ok
          end
        end

      error ->
        error
    end
  end

  defp device_entry(device_id) do
    {:ok, hostname} = :inet.gethostname()

    %{
      "id" => device_id,
      "name" => to_string(hostname),
      "os" => os_name(),
      "registered_at" => DateTime.to_iso8601(DateTime.utc_now(:second))
    }
  end

  defp os_name do
    case :os.type() do
      {:win32, _} -> "windows"
      {:unix, :darwin} -> "macos"
      {:unix, other} -> to_string(other)
    end
  end
end
