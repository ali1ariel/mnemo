defmodule Mnemo.Sync.Blob do
  use Ecto.Schema

  @primary_key {:sha256, :string, autogenerate: false}

  schema "blobs" do
    field :size, :integer
    field :remote_file_id, :string
    field :uploaded_at, :utc_datetime
  end
end
