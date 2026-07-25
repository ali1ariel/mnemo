defmodule Mnemo.Repo.Migrations.AddInstallPathToGames do
  use Ecto.Migration

  # Where the game itself is installed, when it was found next to a save
  # folder. It is what makes real cover art reachable: a Ren'Py build
  # ships an icon, and Steam keeps the official capsule art in its own
  # on-disk cache.
  def change do
    alter table(:games) do
      add :install_path, :string
    end
  end
end
