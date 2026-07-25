defmodule Mnemo.RenPyFixtures do
  @moduledoc """
  Builds `.save` files with the exact member layout observed in real
  Ren'Py 7.8/8.x saves (`screenshot.png`, `extra_info`, `json`,
  `renpy_version`, `log`, `signatures`), without shipping anyone's
  personal save data in the repository.
  """

  # Smallest valid PNG (1×1 transparent pixel).
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  def png, do: @png

  @doc """
  Write a valid save into `dir`. `:seed` varies the `log` member so two
  saves get different hashes; `:save_name` fills the `json` metadata.
  """
  def write_save(dir, filename, opts \\ []) do
    File.mkdir_p!(dir)
    path = Path.join(dir, filename)
    {:ok, _} = :zip.create(to_charlist(path), members(opts))
    path
  end

  @doc "A zip that opens but is missing the `log` and `json` members."
  def write_save_missing_members(dir, filename) do
    File.mkdir_p!(dir)
    path = Path.join(dir, filename)
    {:ok, _} = :zip.create(to_charlist(path), [{~c"screenshot.png", @png}])
    path
  end

  @doc "A save truncated mid-write — the corruption zip validation must catch."
  def write_truncated_save(dir, filename, opts \\ []) do
    path = write_save(dir, filename, opts)
    data = File.read!(path)
    File.write!(path, binary_part(data, 0, div(byte_size(data), 2)))
    path
  end

  def write_garbage_save(dir, filename) do
    File.mkdir_p!(dir)
    path = Path.join(dir, filename)
    File.write!(path, :crypto.strong_rand_bytes(128))
    path
  end

  defp members(opts) do
    seed = Keyword.get(opts, :seed, "seed")

    json =
      Jason.encode!(%{
        "_save_name" => Keyword.get(opts, :save_name, ""),
        "_renpy_version" => [8, 1, 0, 0],
        "_ctime" => 1_700_000_000.0,
        "_version" => "1.0"
      })

    [
      {~c"screenshot.png", Keyword.get(opts, :screenshot, @png)},
      {~c"extra_info", ""},
      {~c"json", json},
      {~c"renpy_version", "Ren'Py 8.1.0.0"},
      {~c"log", "renpy-pickled-log-" <> seed},
      {~c"signatures", ""}
    ]
  end
end
