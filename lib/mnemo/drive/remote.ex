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
    cond do
      game.remote_folder_id != nil ->
        load_game_folder(backend, game.remote_folder_id)

      true ->
        case backend.find_child(games_id, game.id) do
          {:ok, %{folder?: true} = folder} -> load_game_folder(backend, folder.id)
          {:ok, _} -> adopt_or_create(backend, games_id, game)
          error -> error
        end
    end
  end

  defp adopt_or_create(backend, games_id, game) do
    case find_by_save_directory(backend, games_id, game.save_directory) do
      {:ok, nil} -> create_game(backend, games_id, game)
      {:ok, folder_id} -> load_game_folder(backend, folder_id)
      error -> error
    end
  end

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
    game_json =
      Jason.encode!(%{
        "id" => game.id,
        "save_directory" => game.save_directory,
        "name" => game.name,
        "created_by_device" => Settings.device_id(),
        "created_at" => DateTime.to_iso8601(DateTime.utc_now(:second))
      })

    with {:ok, folder} <- backend.create_folder(games_id, game.id),
         {:ok, generations} <- backend.create_folder(folder.id, "generations"),
         {:ok, blobs} <- backend.create_folder(folder.id, "blobs"),
         {:ok, _} <- backend.upload(folder.id, "game.json", game_json, @json_mime) do
      {:ok, %{folder_id: folder.id, generations_id: generations.id, blobs_id: blobs.id}}
    end
  end

  defp load_game_folder(backend, folder_id) do
    with {:ok, generations} <- find_or_create_folder(backend, folder_id, "generations"),
         {:ok, blobs} <- find_or_create_folder(backend, folder_id, "blobs") do
      {:ok, %{folder_id: folder_id, generations_id: generations.id, blobs_id: blobs.id}}
    end
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
