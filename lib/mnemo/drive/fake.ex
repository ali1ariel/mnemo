defmodule Mnemo.Drive.Fake do
  @moduledoc """
  In-memory Drive with the same semantics mnemo relies on: id-addressed
  files, and duplicate names allowed within a folder — which is exactly
  how two devices racing on the same generation number produce a fork.
  """

  @behaviour Mnemo.Drive.Backend

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  ## Backend callbacks

  @impl Mnemo.Drive.Backend
  def list_children(parent_id), do: call({:list_children, parent_id})

  @impl Mnemo.Drive.Backend
  def find_child(parent_id, name), do: call({:find_child, parent_id, name})

  @impl Mnemo.Drive.Backend
  def create_folder(parent_id, name), do: call({:create_folder, parent_id, name})

  @impl Mnemo.Drive.Backend
  def upload(parent_id, name, content, _mime), do: call({:upload, parent_id, name, content})

  @impl Mnemo.Drive.Backend
  def update(id, content, _mime), do: call({:update, id, content})

  @impl Mnemo.Drive.Backend
  def download(id), do: call({:download, id})

  @impl Mnemo.Drive.Backend
  def delete(id), do: call({:delete, id})

  ## Test helpers

  def reset, do: call(:reset)
  def upload_count, do: call(:upload_count)

  @doc "Read a file by path segments from the root, e.g. `~w(mnemo games x game.json)`."
  def read_path(segments), do: call({:read_path, segments})

  @doc "Create a file at the given path, creating folders as needed — simulates another device writing."
  def seed_file(segments, content), do: call({:seed_file, segments, content})

  def list_path(segments), do: call({:list_path, segments})

  defp call(msg), do: GenServer.call(__MODULE__, msg)

  ## Server

  @impl GenServer
  def init(:ok), do: {:ok, initial_state()}

  defp initial_state do
    root = %{id: "root", name: "root", parent_id: nil, content: nil, folder?: true}
    %{files: %{"root" => root}, next_id: 1, upload_count: 0}
  end

  @impl GenServer
  def handle_call(:reset, _from, _state), do: {:reply, :ok, initial_state()}

  def handle_call(:upload_count, _from, state), do: {:reply, state.upload_count, state}

  def handle_call({:list_children, parent_id}, _from, state) do
    if Map.has_key?(state.files, parent_id) do
      {:reply, {:ok, children(state, parent_id) |> Enum.map(&meta/1)}, state}
    else
      {:reply, {:error, %{status: 404, id: parent_id}}, state}
    end
  end

  def handle_call({:find_child, parent_id, name}, _from, state) do
    child = state |> children(parent_id) |> Enum.find(&(&1.name == name))
    {:reply, {:ok, child && meta(child)}, state}
  end

  def handle_call({:create_folder, parent_id, name}, _from, state) do
    {entry, state} = insert(state, parent_id, name, nil, true)
    {:reply, {:ok, meta(entry)}, state}
  end

  def handle_call({:upload, parent_id, name, content}, _from, state) do
    {entry, state} = insert(state, parent_id, name, content, false)
    {:reply, {:ok, meta(entry)}, %{state | upload_count: state.upload_count + 1}}
  end

  def handle_call({:update, id, content}, _from, state) do
    case state.files[id] do
      nil ->
        {:reply, {:error, %{status: 404, id: id}}, state}

      entry ->
        entry = %{entry | content: content}
        {:reply, {:ok, meta(entry)}, put_in(state.files[id], entry)}
    end
  end

  def handle_call({:download, id}, _from, state) do
    case state.files[id] do
      %{folder?: false, content: content} -> {:reply, {:ok, content}, state}
      _ -> {:reply, {:error, %{status: 404, id: id}}, state}
    end
  end

  def handle_call({:delete, id}, _from, state) do
    if Map.has_key?(state.files, id) do
      doomed = [id | descendants(state, id)]
      {:reply, :ok, %{state | files: Map.drop(state.files, doomed)}}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:read_path, segments}, _from, state) do
    case resolve(state, segments) do
      %{content: content, folder?: false} -> {:reply, {:ok, content}, state}
      _ -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:seed_file, segments, content}, _from, state) do
    {parents, [name]} = Enum.split(segments, -1)

    {parent_id, state} =
      Enum.reduce(parents, {"root", state}, fn seg, {pid, st} ->
        case st |> children(pid) |> Enum.find(&(&1.folder? and &1.name == seg)) do
          nil ->
            {entry, st} = insert(st, pid, seg, nil, true)
            {entry.id, st}

          entry ->
            {entry.id, st}
        end
      end)

    {entry, state} = insert(state, parent_id, name, content, false)
    {:reply, {:ok, meta(entry)}, state}
  end

  def handle_call({:list_path, segments}, _from, state) do
    case resolve(state, segments) do
      %{folder?: true, id: id} -> {:reply, {:ok, children(state, id) |> Enum.map(&meta/1)}, state}
      _ -> {:reply, {:error, :not_found}, state}
    end
  end

  defp descendants(state, id) do
    direct = state |> children(id) |> Enum.map(& &1.id)
    direct ++ Enum.flat_map(direct, &descendants(state, &1))
  end

  defp children(state, parent_id) do
    state.files
    |> Map.values()
    |> Enum.filter(&(&1.parent_id == parent_id))
    |> Enum.sort_by(& &1.id)
  end

  defp resolve(state, segments) do
    Enum.reduce_while(segments, state.files["root"], fn seg, entry ->
      case state |> children(entry.id) |> Enum.find(&(&1.name == seg)) do
        nil -> {:halt, nil}
        child -> {:cont, child}
      end
    end)
  end

  defp insert(state, parent_id, name, content, folder?) do
    id = "f#{state.next_id}"
    entry = %{id: id, name: name, parent_id: parent_id, content: content, folder?: folder?}
    {entry, %{state | files: Map.put(state.files, id, entry), next_id: state.next_id + 1}}
  end

  defp meta(entry) do
    %{
      id: entry.id,
      name: entry.name,
      md5: entry.content && Base.encode16(:crypto.hash(:md5, entry.content), case: :lower),
      size: entry.content && byte_size(entry.content),
      folder?: entry.folder?
    }
  end
end
