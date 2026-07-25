defmodule Mnemo.Drive.Backend do
  @moduledoc """
  The minimal Drive surface the sync engine needs.

  `Mnemo.Drive.HTTP` talks to the real API; `Mnemo.Drive.Fake` is an
  in-memory implementation for tests and offline development. Everything
  is addressed by file id, never by path — ids survive renames and moves
  done in the Drive web interface. The literal id `"root"` refers to the
  Drive root.
  """

  @type id :: String.t()
  @type file_meta :: %{
          id: id(),
          name: String.t(),
          md5: String.t() | nil,
          size: non_neg_integer() | nil,
          folder?: boolean()
        }
  @type error :: {:error, term()}

  @callback list_children(id()) :: {:ok, [file_meta()]} | error()
  @callback find_child(id(), String.t()) :: {:ok, file_meta() | nil} | error()
  @callback create_folder(id(), String.t()) :: {:ok, file_meta()} | error()
  @callback upload(id(), String.t(), binary(), String.t()) :: {:ok, file_meta()} | error()
  @callback update(id(), binary(), String.t()) :: {:ok, file_meta()} | error()
  @callback download(id()) :: {:ok, binary()} | error()
  @callback delete(id()) :: :ok | error()

  def impl, do: Application.get_env(:mnemo, :drive_backend, Mnemo.Drive.HTTP)
end
