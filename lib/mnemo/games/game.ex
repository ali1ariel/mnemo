defmodule Mnemo.Games.Game do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "games" do
    field :save_directory, :string
    field :name, :string
    field :install_root, :string, default: "appdata"
    field :cover_blob_sha, :string
    field :enabled, :boolean, default: true
    field :exclude_patterns, {:array, :string}, default: []
    field :sync_autosaves, :boolean, default: false
    field :executable_path, :string
    field :install_path, :string
    field :remote_folder_id, :string
    field :last_generation_seen, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(game, attrs) do
    game
    |> cast(attrs, [
      :save_directory,
      :name,
      :install_root,
      :enabled,
      :exclude_patterns,
      :sync_autosaves,
      :executable_path,
      :install_path
    ])
    |> validate_required([:save_directory, :install_root])
    |> unique_constraint([:save_directory, :install_root])
  end
end
