defmodule Mnemo.Drive.HTTP do
  @moduledoc """
  Google Drive v3 backend over Req.

  Transient failures (429 and 5xx) are retried with backoff by Req itself.
  Save files stay well under the 5 MB multipart limit, so the simple
  multipart upload is enough for v0.
  """

  @behaviour Mnemo.Drive.Backend

  @base_url "https://www.googleapis.com"
  @folder_mime "application/vnd.google-apps.folder"
  @meta_fields "id,name,md5Checksum,size,mimeType"

  @impl true
  def list_children(parent_id) do
    query = "'#{escape(parent_id)}' in parents and trashed = false"
    list_all(query, nil, [])
  end

  @impl true
  def find_child(parent_id, name) do
    query =
      "'#{escape(parent_id)}' in parents and name = '#{escape(name)}' and trashed = false"

    with {:ok, files} <- list_all(query, nil, []) do
      {:ok, List.first(files)}
    end
  end

  @impl true
  def create_folder(parent_id, name) do
    request(:create_folder, fn req ->
      Req.post(req,
        url: "/drive/v3/files",
        params: [fields: @meta_fields],
        json: %{name: name, mimeType: @folder_mime, parents: [parent_id]}
      )
    end)
  end

  @impl true
  def upload(parent_id, name, content, mime) do
    boundary = "mnemo" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    metadata = Jason.encode!(%{name: name, parents: [parent_id]})

    body =
      "--#{boundary}\r\ncontent-type: application/json; charset=UTF-8\r\n\r\n#{metadata}\r\n" <>
        "--#{boundary}\r\ncontent-type: #{mime}\r\n\r\n" <> content <> "\r\n--#{boundary}--"

    request(:upload, fn req ->
      Req.post(req,
        url: "/upload/drive/v3/files",
        params: [uploadType: "multipart", fields: @meta_fields],
        headers: [{"content-type", "multipart/related; boundary=#{boundary}"}],
        body: body
      )
    end)
  end

  @impl true
  def update(file_id, content, mime) do
    request(:update, fn req ->
      Req.patch(req,
        url: "/upload/drive/v3/files/#{file_id}",
        params: [uploadType: "media", fields: @meta_fields],
        headers: [{"content-type", mime}],
        body: content
      )
    end)
  end

  @impl true
  def download(file_id) do
    with {:ok, req} <- base_request() do
      case Req.get(req,
             url: "/drive/v3/files/#{file_id}",
             params: [alt: "media"],
             decode_body: false
           ) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, body}

        {:ok, %{status: status, body: body}} ->
          {:error, %{op: :download, status: status, body: body}}

        {:error, exception} ->
          {:error, %{op: :download, reason: Exception.message(exception)}}
      end
    end
  end

  defp list_all(query, page_token, acc) do
    params =
      [
        q: query,
        fields: "nextPageToken,files(#{@meta_fields})",
        pageSize: 1000,
        spaces: "drive"
      ] ++ if(page_token, do: [pageToken: page_token], else: [])

    result =
      request_raw(:list, fn req -> Req.get(req, url: "/drive/v3/files", params: params) end)

    case result do
      {:ok, %{"files" => files} = body} ->
        acc = acc ++ Enum.map(files, &to_meta/1)

        case body["nextPageToken"] do
          nil -> {:ok, acc}
          token -> list_all(query, token, acc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(op, fun) do
    with {:ok, body} <- request_raw(op, fun) do
      {:ok, to_meta(body)}
    end
  end

  defp request_raw(op, fun) do
    with {:ok, req} <- base_request() do
      case fun.(req) do
        {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
        {:ok, %{status: status, body: body}} -> {:error, %{op: op, status: status, body: body}}
        {:error, exception} -> {:error, %{op: op, reason: Exception.message(exception)}}
      end
    end
  end

  defp base_request do
    with {:ok, token} <- Mnemo.Drive.access_token() do
      {:ok,
       Req.new(
         base_url: @base_url,
         auth: {:bearer, token},
         retry: :transient,
         max_retries: 3
       )}
    end
  end

  defp to_meta(%{"id" => id} = file) do
    %{
      id: id,
      name: file["name"],
      md5: file["md5Checksum"],
      size: file["size"] && String.to_integer(file["size"]),
      folder?: file["mimeType"] == @folder_mime
    }
  end

  defp escape(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("'", "\\'")
  end
end
