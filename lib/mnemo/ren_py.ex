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

  ## Game-local save folders

  @doc """
  Ren'Py installs that keep their saves next to the executable.

  Ren'Py does not pick one save folder — `savelocation.init/0` builds a
  `MultiLocation` out of the user savedir *and* `<gamedir>/saves`, so a
  Steam or itch.io copy reads and writes both at once. Scanning
  `~/.renpy` alone therefore misses half of a game's save locations,
  which is why these are found on their own rather than left to manual
  folder picking.

  An install is recognised by holding both a `renpy/` and a `game/`
  directory — the layout every packaged Ren'Py build has.
  """
  def portable_installs(dirs \\ install_search_dirs()) do
    for base <- dirs,
        install <- list_subdirs(base),
        renpy_install?(install),
        saves = Path.join([install, "game", "saves"]),
        File.dir?(saves) do
      %{path: saves, install: install, name: Path.basename(install)}
    end
    |> Enum.uniq_by(&directory_identity(&1.path))
  end

  # `~/.steam/steam` is a symlink to the real Steam directory on most
  # Linux setups, so the same install is reachable by two paths. Comparing
  # the directory itself rather than the string collapses those, along
  # with bind mounts and any other aliasing.
  defp directory_identity(path) do
    case File.stat(path) do
      {:ok, %{major_device: device, inode: inode}} when inode > 0 -> {device, inode}
      _ -> path
    end
  end

  defp renpy_install?(path) do
    File.dir?(Path.join(path, "renpy")) and File.dir?(Path.join(path, "game"))
  end

  defp list_subdirs(base) do
    case File.ls(base) do
      {:ok, names} ->
        for name <- Enum.sort(names),
            full = Path.join(base, name),
            File.dir?(full),
            do: full

      {:error, _} ->
        []
    end
  end

  @doc "Directories that hold unpacked game installs on this machine."
  def install_search_dirs do
    case Application.get_env(:mnemo, :install_dirs) do
      nil -> steam_common_dirs() ++ other_install_dirs()
      dirs -> dirs
    end
  end

  defp other_install_dirs do
    ~w(~/Games ~/games ~/.itch/apps ~/.config/itch/apps)
    |> Enum.map(&Path.expand/1)
    |> Enum.filter(&File.dir?/1)
  end

  # Steam spreads games across libraries the user added on other disks;
  # libraryfolders.vdf is the only list of them.
  defp steam_common_dirs do
    steam_roots()
    |> Enum.flat_map(fn root -> [root | library_paths(root)] end)
    |> Enum.map(&Path.join([&1, "steamapps", "common"]))
    |> Enum.uniq()
    |> Enum.filter(&File.dir?/1)
  end

  defp steam_roots do
    ~w(~/.local/share/Steam ~/.steam/steam ~/Library/Application\ Support/Steam)
    |> Enum.map(&Path.expand/1)
    |> then(fn roots ->
      case System.get_env("PROGRAMFILES(X86)") do
        nil -> roots
        pf -> [Path.join(pf, "Steam") | roots]
      end
    end)
    |> Enum.filter(&File.dir?/1)
  end

  defp library_paths(steam_root) do
    vdf = Path.join([steam_root, "steamapps", "libraryfolders.vdf"])

    case File.read(vdf) do
      {:ok, contents} ->
        Regex.scan(~r/"path"\s+"([^"]+)"/, contents, capture: :all_but_first)
        |> List.flatten()

      {:error, _} ->
        []
    end
  end

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
    user_entries =
      for root <- scan_roots,
          dir <- list_dirs(root),
          entry = scan_entry(root, dir),
          entry != nil,
          do: entry

    group_mirrors(user_entries ++ portable_entries())
  end

  @doc """
  Collapse folders that are the same game into one entry.

  Ren'Py's `MultiLocation` writes every save to all of its locations and
  deletes from all of them, so a Steam or itch.io copy is a mirror of the
  user savedir, not a second game. Listing them separately would invite
  enrolling one game twice, giving it two lineages and two histories for
  no benefit.

  The surviving entry keeps the user savedir when there is one — it
  outlives uninstalling and reinstalling the game — and carries the other
  paths in `:mirrors`.
  """
  def group_mirrors(entries) do
    entries
    |> Enum.reduce([], fn entry, groups ->
      case Enum.find_index(groups, &mirrors?(&1, entry)) do
        nil -> groups ++ [[entry]]
        index -> List.update_at(groups, index, &(&1 ++ [entry]))
      end
    end)
    |> Enum.map(&merge_group/1)
  end

  defp mirrors?(group, entry) do
    Enum.any?(group, fn other -> MapSet.size(shared_saves(other, entry)) > 0 end)
  end

  # Identical name and byte size on a `.save` is proof enough of a mirror:
  # these are multi-megabyte archives, and Ren'Py wrote both copies from
  # the same bytes. Hashing every file on every scan would cost far more
  # for no extra certainty.
  defp shared_saves(a, b), do: MapSet.intersection(save_signature(a), save_signature(b))

  defp save_signature(%{path: path}) do
    path
    |> save_files()
    |> Enum.flat_map(fn file ->
      case File.stat(file) do
        {:ok, %{size: size}} -> [{Path.basename(file), size}]
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  defp merge_group([entry]), do: Map.put(entry, :mirrors, [])

  defp merge_group(entries) do
    primary = Enum.find(entries, List.first(entries), &(&1.kind == :user))

    Map.put(primary, :mirrors, entries |> Enum.reject(&(&1 == primary)) |> Enum.map(& &1.path))
  end

  # A game-local save folder is always called `saves`, so the install
  # directory name is what identifies it to a person and to the remote.
  defp portable_entries do
    for %{path: path, install: install, name: name} <- portable_installs() do
      saves = save_files(path)

      %{
        root: Path.dirname(path),
        save_directory: Path.basename(path),
        path: path,
        name: name,
        kind: :portable,
        install: install,
        save_count: length(saves),
        latest_save_at: latest_mtime(saves),
        preview: preview_screenshot(path)
      }
    end
  end

  defp list_dirs(root) do
    case File.ls(root) do
      {:ok, names} -> names |> Enum.reject(&internal_dir?/1) |> Enum.sort()
      {:error, _} -> []
    end
  end

  @internal_dir_re ~r/\.(bak|mnemo-restore)-\d+$/

  @doc """
  Directories mnemo itself puts next to a game folder: restore backups
  and staging areas.

  They hold real `.save` files, so the scan has to skip them — otherwise
  a restore backup would show up on the enrollment screen as a game of
  its own.
  """
  def internal_dir?(name), do: Regex.match?(@internal_dir_re, name)

  defp scan_entry(root, dir) do
    path = Path.join(root, dir)
    saves = save_files(path)
    persistent? = File.regular?(Path.join(path, "persistent"))

    if File.dir?(path) and (saves != [] or persistent?) do
      %{
        root: root,
        save_directory: dir,
        path: path,
        name: suggest_name(dir),
        kind: :user,
        install: nil,
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

  @doc """
  Every save slot in a game folder with display metadata, unsorted.

  A corrupt save still shows up (with `screenshot?: false`) — hiding it
  would make the slot silently disappear from the interface while the
  file sits broken on disk.
  """
  def list_saves(path) do
    case File.ls(path) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.flat_map(fn name -> save_entry(path, name) end)

      {:error, _} ->
        []
    end
  end

  defp save_entry(path, name) do
    slot = parse_slot(name)
    full = Path.join(path, name)

    with true <- slot not in [:other, :persistent],
         {:ok, %{type: :regular, size: size, mtime: mtime}} <- File.stat(full, time: :posix) do
      [
        %{
          file: name,
          slot: slot,
          size: size,
          mtime: DateTime.from_unix!(mtime),
          save_name: save_display_name(full),
          screenshot?: screenshot_member?(full)
        }
      ]
    else
      _ -> []
    end
  end

  defp save_display_name(path) do
    case save_metadata(path) do
      {:ok, %{"_save_name" => name}} when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp screenshot_member?(path) do
    case :zip.list_dir(to_charlist(path)) do
      {:ok, entries} ->
        Enum.any?(entries, fn entry ->
          elem(entry, 0) == :zip_file and elem(entry, 1) == @screenshot_member
        end)

      {:error, _} ->
        false
    end
  rescue
    _ -> false
  end

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
  rescue
    e -> {:error, Exception.message(e)}
  end
end
