defmodule Mnemo.RenPy do
  @moduledoc """
  Everything mnemo knows about Ren'Py on disk: OS roots, save folder
  scanning, slot name parsing, and the `.save` zip format.

  A `.save` is a zip archive; the members observed in Ren'Py 7.8/8.x are
  `log`, `json`, `screenshot.png`, `extra_info`, `renpy_version` and
  `signatures`. `log` and `json` are treated as required.
  """

  @screenshot_member ~c"screenshot.png"
  @required_members [~c"log", ~c"json"]

  # Slot names are free-form, not numeric: real games write files such as
  # "1-Save Slot 9-LT1.save". The "-LT<n>" token suffix exists only in
  # newer Ren'Py versions.
  @slot_re ~r/^(\d+)-(.+?)(?:-LT\d+)?\.save$/
  @auto_re ~r/^auto-(\d+)(?:-LT\d+)?\.save$/
  @quick_re ~r/^quick-(\d+)(?:-LT\d+)?\.save$/

  ## Roots and paths

  @doc """
  Candidate Ren'Py roots on this machine, most specific first.

  On Linux this includes every Proton prefix that contains a RenPy
  folder — a Windows game running under Proton writes there, not to
  `~/.renpy`.
  """
  def roots do
    case Application.get_env(:mnemo, :renpy_roots) do
      nil -> detect_roots()
      roots -> roots
    end
  end

  @doc "The OS-default root, which `install_root: \"appdata\"` resolves to."
  def default_root do
    case Application.get_env(:mnemo, :renpy_roots) do
      nil -> native_root()
      [root | _] -> root
      [] -> nil
    end
  end

  defp detect_roots do
    proton =
      Path.wildcard(
        Path.expand(
          "~/.steam/steam/steamapps/compatdata/*/pfx/drive_c/users/steamuser/AppData/Roaming/RenPy"
        )
      )

    Enum.filter([native_root() | proton], &(&1 && File.dir?(&1)))
  end

  defp native_root do
    case :os.type() do
      {:win32, _} ->
        appdata = System.get_env("APPDATA")
        appdata && Path.join(appdata, "RenPy")

      {:unix, :darwin} ->
        Path.expand("~/Library/RenPy")

      {:unix, _} ->
        Path.expand("~/.renpy")
    end
  end

  def resolve_root("appdata"), do: default_root()
  def resolve_root(absolute), do: absolute

  def game_path(%{install_root: install_root, save_directory: save_directory}) do
    case resolve_root(install_root) do
      nil -> nil
      root -> Path.join(root, save_directory)
    end
  end

  ## Scanning

  @doc """
  Enumerate every game under the given roots (default: this machine's).

  A subfolder counts as a game when it holds at least one `.save` or a
  `persistent` file — this filters out Ren'Py's own `tokens` folder.
  """
  def scan(scan_roots \\ roots()) do
    for root <- scan_roots,
        dir <- list_dirs(root),
        entry = scan_entry(root, dir),
        entry != nil,
        do: entry
  end

  defp list_dirs(root) do
    case File.ls(root) do
      {:ok, names} -> Enum.sort(names)
      {:error, _} -> []
    end
  end

  defp scan_entry(root, dir) do
    path = Path.join(root, dir)
    saves = save_files(path)
    persistent? = File.regular?(Path.join(path, "persistent"))

    if File.dir?(path) and (saves != [] or persistent?) do
      %{
        root: root,
        save_directory: dir,
        path: path,
        save_count: length(saves),
        latest_save_at: latest_mtime(saves),
        preview: preview_screenshot(path)
      }
    end
  end

  defp save_files(path) do
    case File.ls(path) do
      {:ok, names} ->
        for name <- names,
            String.ends_with?(name, ".save"),
            full = Path.join(path, name),
            File.regular?(full),
            do: full

      {:error, _} ->
        []
    end
  end

  defp latest_mtime([]), do: nil

  defp latest_mtime(files) do
    files
    |> Enum.map(&file_mtime/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> DateTime.from_unix!(mtime)
      {:error, _} -> nil
    end
  end

  @doc "Most recently written `.save` in a game folder, or nil."
  def latest_save(path) do
    path
    |> save_files()
    |> Enum.max_by(&(file_mtime(&1) || ~U[1970-01-01 00:00:00Z]), DateTime, fn -> nil end)
  end

  defp preview_screenshot(path) do
    with latest when is_binary(latest) <- latest_save(path),
         {:ok, png} <- extract_screenshot(latest) do
      png
    else
      _ -> nil
    end
  end

  @doc """
  A readable name guessed from the folder name, e.g.
  `"CampBuddyScoutmastersSeason-1608150621"` → `"Camp Buddy Scoutmasters
  Season"`. The user can rename later; this is only the starting point.
  """
  def suggest_name(save_directory) do
    save_directory
    |> String.replace(~r/-\d+$/, "")
    |> String.replace(~r/[_-]+/, " ")
    |> String.replace(~r/([a-z\d])([A-Z])/, "\\1 \\2")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  ## Slot names

  @doc """
  Classify a file name the way Ren'Py's save screens do.

  Returns `{:slot, page, name}`, `{:auto, n}`, `{:quick, n}`,
  `:persistent` or `:other`. Names starting with `_` (such as
  `_reload-1.save`) are Ren'Py-internal and classify as `:other`.
  """
  def parse_slot("persistent"), do: :persistent
  def parse_slot("_" <> _), do: :other

  def parse_slot(name) do
    cond do
      captures = Regex.run(@auto_re, name) ->
        [_, n] = captures
        {:auto, String.to_integer(n)}

      captures = Regex.run(@quick_re, name) ->
        [_, n] = captures
        {:quick, String.to_integer(n)}

      captures = Regex.run(@slot_re, name) ->
        [_, page, slot_name] = captures
        {:slot, String.to_integer(page), slot_name}

      true ->
        :other
    end
  end

  def slot_to_map(:persistent), do: %{"type" => "persistent"}
  def slot_to_map({:auto, n}), do: %{"type" => "auto", "n" => n}
  def slot_to_map({:quick, n}), do: %{"type" => "quick", "n" => n}
  def slot_to_map({:slot, page, name}), do: %{"type" => "slot", "page" => page, "name" => name}

  ## Tracked files

  @doc """
  Files in a game folder that belong in a snapshot, as `{rel_path, slot}`.

  Only top-level files are considered — Ren'Py's own `sync/` staging
  folder must not be picked up. Autosaves and quicksaves are skipped
  unless `sync_autosaves` is set; they multiply generations without
  proportional value.
  """
  def tracked_files(path, opts \\ []) do
    sync_autosaves? = Keyword.get(opts, :sync_autosaves, false)
    exclude = Keyword.get(opts, :exclude_patterns, []) |> Enum.map(&glob_to_regex/1)

    case File.ls(path) do
      {:ok, names} ->
        for name <- Enum.sort(names),
            File.regular?(Path.join(path, name)),
            slot = parse_slot(name),
            slot != :other,
            sync_autosaves? or not autosave?(slot),
            not Enum.any?(exclude, &Regex.match?(&1, name)),
            do: {name, slot}

      {:error, _} ->
        []
    end
  end

  defp autosave?({:auto, _}), do: true
  defp autosave?({:quick, _}), do: true
  defp autosave?(_), do: false

  defp glob_to_regex(pattern) do
    escaped =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    Regex.compile!("^#{escaped}$")
  end

  ## Zip format

  @doc """
  Open and fully extract a `.save` in memory, checking CRCs.

  This is what prevents propagating a truncated file captured mid-write —
  the one scenario where mnemo would destroy data.
  """
  def validate_save(path) do
    collect = fn name, _info, get_bin, acc ->
      _content = get_bin.()
      [name | acc]
    end

    case safe_foldl(collect, to_charlist(path)) do
      {:ok, members} ->
        case @required_members -- members do
          [] ->
            :ok

          missing ->
            {:error, %{file: Path.basename(path), missing: Enum.map(missing, &to_string/1)}}
        end

      {:error, reason} ->
        {:error, %{file: Path.basename(path), reason: reason}}
    end
  end

  # :zip raises on some malformed archives instead of returning an error.
  defp safe_foldl(fun, path) do
    case :zip.foldl(fun, [], path) do
      {:ok, members} -> {:ok, members}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  def extract_screenshot(path) do
    case :zip.extract(to_charlist(path), [{:file_list, [@screenshot_member]}, :memory]) do
      {:ok, [{_name, png}]} -> {:ok, png}
      {:ok, []} -> {:error, :no_screenshot}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Decoded `json` member: save name, Ren'Py version, creation time."
  def save_metadata(path) do
    with {:ok, [{_name, json}]} <-
           :zip.extract(to_charlist(path), [{:file_list, [~c"json"]}, :memory]),
         {:ok, meta} <- Jason.decode(json) do
      {:ok, meta}
    else
      {:ok, []} -> {:error, :no_metadata}
      {:error, reason} -> {:error, reason}
    end
  end
end
