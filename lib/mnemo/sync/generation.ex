defmodule Mnemo.Sync.Generation do
  use Ecto.Schema

  schema "generations" do
    belongs_to :game, Mnemo.Games.Game, type: :binary_id
    field :number, :integer
    field :parent_number, :integer
    field :device_id, :string
    field :validated, :boolean, default: false
    field :byte_size, :integer, default: 0
    field :remote_manifest_id, :string
    field :manifest, {:array, :map}

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
