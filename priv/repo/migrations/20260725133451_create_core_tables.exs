defmodule Mnemo.Repo.Migrations.CreateCoreTables do
  use Ecto.Migration

  def change do
    create table(:games, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :save_directory, :string, null: false
      add :name, :string
      add :install_root, :string, null: false, default: "appdata"
      add :cover_blob_sha, :string
      add :enabled, :boolean, null: false, default: true
      add :exclude_patterns, :map
      add :sync_autosaves, :boolean, null: false, default: false
      add :executable_path, :string
      add :remote_folder_id, :string
      add :last_generation_seen, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:games, [:save_directory, :install_root])

    create table(:generations) do
      add :game_id, references(:games, type: :binary_id, on_delete: :delete_all), null: false
      add :number, :integer, null: false
      add :parent_number, :integer, null: false
      add :device_id, :string, null: false
      add :validated, :boolean, null: false, default: false
      add :byte_size, :integer, null: false, default: 0
      add :remote_manifest_id, :string
      add :manifest, :map, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:generations, [:game_id, :number, :device_id])

    create table(:blobs, primary_key: false) do
      add :sha256, :string, primary_key: true
      add :size, :integer, null: false
      add :remote_file_id, :string
      add :uploaded_at, :utc_datetime, null: false
    end

    create table(:settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :string
    end
  end
end
