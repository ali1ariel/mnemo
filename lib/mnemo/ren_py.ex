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
      _ -> canonical_path(path)
    end
  end

  # Windows reports no inode, so on that platform the fallback above is
  # the only comparison there is and it has to do the work: `\` and `/`
  # both separate, runs of either collapse, and the filesystem does not
  # distinguish case. On Unix a backslash is a legal character in a file
  # name and is left alone.
  defp canonical_path(path) do
    case :os.type() do
      {:win32, _} ->
        path |> String.replace("\\", "/") |> collapse_separators() |> String.downcase()

      _ ->
        collapse_separators(path)
    end
  end

  defp collapse_separators(path) do
    case String.replace(path, ~r|/{2,}|, "/") do
      "/" -> "/"
      collapsed -> String.trim_trailing(collapsed, "/")
    end
  end

  @doc "Whether two paths name the same directory, through symlinks and all."
  def same_directory?(a, b), do: directory_identity(a) == directory_identity(b)

  @doc """
  The other places Ren'Py writes this game's saves.

  `savelocation.init/0` builds a `MultiLocation` from the user savedir
  *and* `<gamedir>/saves`, and every save goes to all of them while every
  delete removes from all of them. A game installed as a package
  therefore has a second copy of its saves that mnemo does not track but
  the engine still reads — and `load` takes the newest across locations,
  so a slot left behind in one of them comes back to life.

  Derived from `install_path`, which enrollment records, so no extra
  state is kept for it.
  """
  def mirror_paths(%{install_path: install}) when is_binary(install) do
    saves = Path.join([install, "game", "saves"])
    if File.dir?(saves), do: [saves], else: []
  end

  def mirror_paths(_game), do: []

  @doc "Mirror locations that are not the folder mnemo already tracks."
  def other_locations(game) do
    case game_path(game) do
      nil -> []
      path -> game |> mirror_paths() |> Enum.reject(&same_directory?(&1, path))
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
    |> Enum.uniq_by(&canonical_path/1)
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
      {:ok, contents} -> parse_library_paths(contents)
      {:error, _} -> []
    end
  end

  @doc """
  The library directories listed in a `libraryfolders.vdf`.

  VDF stores quoted strings with escapes, so a Windows library is written
  `C:\\\\Program Files (x86)\\\\Steam` and the raw capture is not a path
  anybody else on the machine spells that way. Unescaping is what keeps
  the enrollment screen honest: the default library also arrives from
  `%PROGRAMFILES(X86)%`, and two spellings of one directory scan as two
  Steam installs, listing every game found under it twice.
  """
  def parse_library_paths(contents) do
    ~r/"path"\s+"((?:[^"\\]|\\.)*)"/
    |> Regex.scan(contents, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&Regex.replace(~r/\\(.)/, &1, "\\1"))
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
    Enum.any?(group, fn other -> same_game?(other.path, entry.path) end)
  end

  @doc """
  Whether two save folders hold the same game's saves.

  Nothing in either folder names the other, and the two names look
  nothing alike — `SleepoverReWake-1755701445` next to `Sleepover
  reWake` — so what they contain is the only link there is.
  """
  def same_game?(a, b) do
    same_directory?(a, b) or MapSet.size(shared_saves(a, b)) > 0
  end

  defp shared_saves(a, b), do: MapSet.intersection(save_signature(a), save_signature(b))

  # Identical name and byte size on a `.save` is proof enough: these are
  # multi-megabyte archives and Ren'Py wrote both copies from the same
  # bytes, so hashing them on every scan would cost far more for no extra
  # certainty.
  #
  # `persistent` is the exception, and it is the one that decides the
  # common case. A game installed and launched but never saved has
  # nothing else in either folder — which is exactly the state rule 2
  # asks the player to be in before enrolling, so matching on `.save`
  # alone fails precisely when enrollment happens, and the game lists
  # twice. It is also kilobytes rather than megabytes, small enough that
  # two unrelated games could share a size, so it is compared by content
  # instead: a coincidence there would merge two different games into one
  # lineage.
  defp save_signature(path) do
    path
    |> save_files()
    |> Enum.flat_map(fn file ->
      case File.stat(file) do
        {:ok, %{size: size}} -> [{Path.basename(file), size}]
        _ -> []
      end
    end)
    |> Enum.concat(persistent_signature(path))
    |> MapSet.new()
  end

  # An empty `persistent` is a write that did not finish rather than
  # evidence of anything: two of them hash alike, and taking that for a
  # match would merge two unrelated games.
  defp persistent_signature(path) do
    case File.read(Path.join(path, "persistent")) do
      {:ok, ""} -> []
      {:ok, contents} -> [{"persistent", :crypto.hash(:sha256, contents)}]
      {:error, _} -> []
    end
  end

  defp merge_group([entry]), do: Map.put(entry, :mirrors, [])

  defp merge_group(entries) do
    primary = Enum.find(entries, List.first(entries), &(&1.kind == :user))

    primary
    |> Map.put(:mirrors, entries |> Enum.reject(&(&1 == primary)) |> Enum.map(& &1.path))
    # The user savedir wins as the folder to track, but only the mirror
    # knows where the game is installed — and that is where the artwork
    # and the icon live.
    |> Map.put(:install, Enum.find_value(entries, & &1[:install]))
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

  @internal_dir_re ~r/\.(?:bak|mnemo-[a-z]+)-\d+$/

  @doc """
  Directories mnemo itself puts next to a game folder: backups and
  staging areas.

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
          save_name: save_name(full),
          screenshot?: screenshot_member?(full)
        }
      ]
    else
      _ -> []
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

  @typedoc """
  A `.save` to read: a path, or `{name, bytes}` for one still held in
  memory — which is what a save nested inside an imported archive is.
  """
  @type archive :: Path.t() | {String.t(), binary()}

  # An in-memory archive is what lets a save nested in an imported zip be
  # read without unpacking the outer one to disk. The two :zip entry
  # points disagree on how to receive it: foldl/3 wants the name beside
  # the bytes, extract/2 wants the bytes alone.
  defp fold_source({name, bytes}) when is_binary(bytes), do: {to_charlist(name), bytes}
  defp fold_source(path), do: to_charlist(path)

  defp extract_source({_name, bytes}) when is_binary(bytes), do: bytes
  defp extract_source(path), do: to_charlist(path)

  defp archive_name({name, _bytes}), do: Path.basename(name)
  defp archive_name(path), do: Path.basename(path)

  @doc """
  Open and fully extract a `.save` in memory, checking CRCs.

  This is what prevents propagating a truncated file captured mid-write —
  the one scenario where mnemo would destroy data.
  """
  @spec validate_save(archive()) :: :ok | {:error, map()}
  def validate_save(archive) do
    collect = fn name, _info, get_bin, acc ->
      _content = get_bin.()
      [name | acc]
    end

    case safe_foldl(collect, fold_source(archive)) do
      {:ok, members} ->
        case @required_members -- members do
          [] ->
            :ok

          missing ->
            {:error, %{file: archive_name(archive), missing: Enum.map(missing, &to_string/1)}}
        end

      {:error, reason} ->
        {:error, %{file: archive_name(archive), reason: reason}}
    end
  end

  # :zip raises on some malformed archives instead of returning an error.
  defp safe_foldl(fun, source) do
    case :zip.foldl(fun, [], source) do
      {:ok, members} -> {:ok, members}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Walk every member of a zip once, folding with
  `fun.(name, get_info, get_bin, acc)`.

  Reading a large archive member by member beats extracting it: only the
  bytes the caller keeps stay in memory.
  """
  @spec fold_members((charlist(), (-> tuple()), (-> binary()), acc -> acc), acc, archive()) ::
          {:ok, acc} | {:error, term()}
        when acc: term()
  def fold_members(fun, acc, archive), do: safe_foldl(fun, acc, fold_source(archive))

  defp safe_foldl(fun, acc, source) do
    :zip.foldl(fun, acc, source)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  @spec extract_screenshot(archive()) :: {:ok, binary()} | {:error, term()}
  def extract_screenshot(archive) do
    case :zip.extract(extract_source(archive), [{:file_list, [@screenshot_member]}, :memory]) do
      {:ok, [{_name, png}]} -> {:ok, png}
      {:ok, []} -> {:error, :no_screenshot}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Decoded `json` member: save name, Ren'Py version, creation time."
  @spec save_metadata(archive()) :: {:ok, map()} | {:error, term()}
  def save_metadata(archive) do
    with {:ok, [{_name, json}]} <-
           :zip.extract(extract_source(archive), [{:file_list, [~c"json"]}, :memory]),
         {:ok, meta} <- Jason.decode(json) do
      {:ok, meta}
    else
      {:ok, []} -> {:error, :no_metadata}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "The player-facing name a save carries, or nil."
  @spec save_name(archive()) :: String.t() | nil
  def save_name(archive) do
    case save_metadata(archive) do
      {:ok, %{"_save_name" => name}} when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end
end
