# mnemo — project specification

> Context document for a coding assistant. Also serves as `CLAUDE.md` at the repository root.
>
> All development happens in English: documentation, code, identifiers, comments, commit messages.

## Context

`mnemo` syncs **Ren'Py game saves** to a folder in Google Drive. It runs in the background with a local Phoenix LiveView web interface, and is later distributed as a packaged desktop application.

The scope is Ren'Py and only Ren'Py. This is not a temporary limitation to be generalized later — it is the premise that makes the project tractable. Knowing the engine eliminates path discovery, provides real integrity validation, solves cover art without an external API, and allows an interface that speaks in pages and slots rather than files. Do not introduce abstractions for "other engines".

The project was generated with:

```
mix phx.new mnemo --database sqlite3 --no-mailer
```

Gettext is included deliberately.

## Stack

- Elixir + Phoenix LiveView
- Ecto + SQLite (`ecto_sqlite3` / `exqlite`)
- **No Ash Framework** — plain Ecto with hand-written context modules
- Gettext with English msgids, `default_locale: "en"`, `pt_BR` translation
- LiveDashboard kept (the application is a tree of GenServers; the process tab is a working tool)
- Future packaging: Tauri + ElixirKit

Do not use `phx.gen.live` or `phx.gen.context`. The generated CRUD assumes screens that edit the database directly; these screens reflect live GenServer state over PubSub. Use `phx.gen.schema` only to create tables.

## What a Ren'Py game looks like to mnemo

Every Ren'Py game writes to `<OS Ren'Py root>/<save_directory>`, where `save_directory` comes from `config.save_directory` and names the subfolder.

Roots per system:

- Windows: `%APPDATA%\RenPy\`
- Linux: `~/.renpy/`
- macOS: `~/Library/RenPy/`
- Proton (Windows game running on Linux): `~/.steam/steam/steamapps/compatdata/<appid>/pfx/drive_c/users/steamuser/AppData/Roaming/RenPy/`

Inside a game's folder:

- `<page>-<slot>-LT1.save` — regular saves (`1-1-LT1.save`, `2-4-LT1.save`)
- `auto-<n>-LT1.save` — autosaves
- `quick-<n>-LT1.save` — quicksaves
- `persistent` — unlocked content, seen text, global choices

Each `.save` is a **zip archive** containing the screenshot taken at save time plus metadata that Ren'Py itself uses to render the slot. Confirm the exact zip member names against the target Ren'Py version before implementing extraction.

**Portable installs:** itch.io builds frequently write to `game/saves` next to the executable and never touch the roots above. Scanning will not find these games — which is why manual folder-picking enrollment is required, not optional.

### Design consequences

**Discovery is a scan, not a catalog.** Listing subfolders of the OS root enumerates every game. No manifest, no PCGamingWiki, no per-game path configuration.

**Identity is `save_directory` plus a UUID.** The path is never stored as identity; it is always derived from `os_root + save_directory`. This solves the Proton case without a per-game mapping table.

**Cover art comes from the save itself.** A game's default cover is the screenshot extracted from its most recent save. There is no SteamGridDB, IGDB, or Steam CDN integration — coverage for Ren'Py and itch.io titles is poor, and the embedded screenshot is better and free. Manual image upload overrides it for anyone who wants that.

**Compression is unnecessary.** `.save` is a zip and `persistent` is already compressed. Do not add a compression layer; upload bytes as they are.

**`persistent` is progress and must be synced**, but it is the highest-churn file — Ren'Py rewrites it during reading as text is seen. A change to `persistent` alone should not trigger sync with the same urgency as a new `.save`; use a longer debounce window for it.

## Architecture

Core separation: **GenServers run the sync engine; SQLite holds the persisted record; LiveView observes.** Live process state is the source for the UI; the database is updated at meaningful checkpoints (snapshot created, generation confirmed, conflict detected), never on every debounce transition.

```
Mnemo.Application
├── Mnemo.Repo
├── Phoenix.PubSub
├── Mnemo.Game.Registry          # Registry, keys: :unique
├── Mnemo.Game.Supervisor        # DynamicSupervisor, one child per game
│   └── Mnemo.Game.Server        # GenServer + state machine
├── Mnemo.Watcher                # file_system + Port.monitor + restart
├── Mnemo.Reconciler             # periodic safety sweep
├── Mnemo.RenPy                  # slot name parsing, zip, screenshot
├── Mnemo.Drive                  # GenServer: token, refresh, rate limit
├── Task.Supervisor              # bounded concurrent uploads
└── MnemoWeb.Endpoint            # loopback
```

`Game.Server` states: `:idle → :dirty → :settling → :snapshotting → :uploading → :ok | :conflict | :error`.

### Errors are structured, never strings

The engine returns `{:error, :upload_failed, %{sha: hash, attempt: 3}}`, not `{:error, "upload failed"}`. Language is a presentation-layer decision. This is an i18n requirement and it also makes errors testable and usable in retry policy.

## Local data model (SQLite)

**`games`** — `id` (uuid), `save_directory` (Ren'Py subfolder name), `name` (user-editable), `install_root` (`:appdata` or an absolute path, for portable installs), `cover_blob_sha` (null = use most recent save's screenshot), `enabled`, `exclude_patterns`, `sync_autosaves` (boolean), `executable_path` (optional), `remote_folder_id`, `last_generation_seen`

**`generations`** — `id`, `game_id`, `number`, `parent_number`, `device_id`, `validated`, `byte_size`, `remote_manifest_id`, `inserted_at`, `manifest` (JSON column with the file list: `rel_path`, `sha256`, `size`, `slot` — page/slot parsed from the name, or `:auto`, `:quick`, `:persistent`)

The file list is a JSON column, **not** a separate table. Access is always "read the whole manifest" for diffing and restore; diffing two manifests is map comparison in Elixir. As a table it would produce thousands of rows per generation with no query benefit.

**`blobs`** — `sha256` (PK), `size`, `remote_file_id`, `uploaded_at`. This is the index that makes deduplication work: before uploading a file, look up its hash here.

**`settings`** — key/value: this machine's `device_id`, the Drive root folder ID, preferred locale.

### Database invariant

**Deleting the SQLite file and restarting must lose nothing.** The application rebuilds state from the remote plus a local scan. The database is cache and machine state, not source of truth. Test this periodically during development.

### The local database is NOT synced

`last_generation_seen` is what this device last saw — it is the entire conflict detection mechanism. Syncing it turns detection off. `install_root` belongs to this installation. `blobs` is what this machine has uploaded. `device_id` exists in order to differ.

Beyond that, SQLite in WAL mode is three files (`.db`, `-wal`, `-shm`), and copying them without atomicity yields a corrupt database.

Metadata that should be shared across machines lives in the remote, in `game.json`.

## Remote model (Google Drive)

```
/mnemo/
├── devices.json                    # append-only machine registry
└── games/<game_uuid>/
    ├── game.json                   # save_directory, canonical name, cover, exclusions
    ├── generations/
    │   ├── 000001.json             # manifest, never overwritten
    │   └── 000002.json
    └── blobs/<sha256>
```

OAuth scope: **`drive.file`** only. Store **file and folder IDs**, never paths — IDs survive renames and moves performed by the user in the Drive web interface.

`game.json` carries the `save_directory`, which is what lets machine B locate the matching folder on its own when enrolling the same game.

## Sync protocol

Each generation records `{number, parent_number, device_id, timestamp, files}`.

**Fast-forward:** if `remote.head == local.last_generation_seen`, upload as `number + 1`.

**Conflict:** if the remote head is higher, another device wrote after this one. Never merge automatically — a Ren'Py save is serialized pickle data inside a zip and does not merge. Preserve both sides and require explicit resolution, with three options: keep local, keep remote, **keep both** (fork the lineage). The third is the only one that never loses data and should be the suggested default.

**Manifests are append-only.** Never overwrite. Drive offers no compare-and-swap; append-only gives race detection for free: two devices writing generation 5 produce two files, which is the signature of a fork and falls into the conflict resolution that already exists. No distributed lock.

**Generation orders; timestamp only decorates.** Never use the local clock to decide precedence — time zones, DST, dual boot, clock drift between machines. Timestamps exist to be displayed in the interface.

**Enrollment and conflict are the same code path.** Local state with unknown lineage versus the remote head is the definition of a conflict. `Game.Server` enters `:conflict` on first enrollment when a remote already exists.

## Inviolable rules

1. **The application never creates a save directory.** Every folder it writes to was created by the game. This eliminates the entire class of "wrote to the wrong place" bugs.
2. **A reference save is required on every machine**, even an empty one. It is what proves the game is installed and identifies the folder to track. If absent, instruct the user to launch the game once and quit — Ren'Py creates the folder and writes `persistent` on first launch.
3. **Snapshot before any overwrite**, including at enrollment. "Overwrite" must never be irreversible.
4. **Validate the zip before accepting a snapshot.** Every `.save` must open and parse. This costs milliseconds and prevents propagating a truncated file captured mid-write — the scenario in which mnemo destroys the user's data.
5. **Retention never deletes the last generation verified as intact**, regardless of policy or age.
6. **Never restore while the game is running.** See the detection section below.
7. **Restore is recoverable mid-operation.** Write to a temp folder on the same volume → rename the current one to `.bak-<timestamp>` → move the new one into place → delete `.bak` on success. On startup, detect an orphaned `.bak` and offer rollback.
8. **Never auto-merge saves.**

### Detecting a running game

The executable name is not derivable from `save_directory`, so reliable automatic detection does not exist in v1. Strategy:

- For **syncing** (the safe direction), file quiescence is enough: Ren'Py writes `persistent` on exit, so a quiet window after that is a sufficient signal.
- For **restoring** (the destructive direction), require explicit user confirmation that the game is closed, combined with a quiescence check. Restoring underneath an open game makes the game overwrite everything on exit, and the user sees "success" while losing the data.
- Optionally, the user associates the executable path at enrollment (`executable_path`); when present, the check becomes automatic.

## Sync cycle

```
watcher fires
  → debounce (30–60s of quiet; longer window if only `persistent` changed)
  → snapshot to a temp directory
  → validate every `.save` as a zip
  → hash (:crypto.hash(:sha256, ...))
  → look up blobs; upload only new hashes
  → write the generation N+1 manifest
  → update local state and PubSub.broadcast
```

`Reconciler` runs every 5–10 minutes comparing local hashes against the last manifest. It is the safety net for a dead watcher, events lost across suspend/hibernate, and external edits. Without it, a dead port process leaves syncing silently deaf.

`Watcher` wraps `file_system` with `Port.monitor` and restarts the port when it dies.

Autosaves and quicksaves change every few minutes of play. Respect `sync_autosaves` per game, off by default — syncing them multiplies generations without proportional value.

## Interface

The interface speaks Ren'Py, not files.

- **Library** — grid of games with cover (most recent save's screenshot), last sync, and state.
- **Enroll** — scan the OS root listing found subfolders, with a preview screenshot so the user can recognize the game (`save_directory` is usually cryptic). Plus a manual folder-picking button for portable installs.
- **Slots** — grid of pages and slots the way Ren'Py renders them, with each save's screenshot. Autosaves and quicksaves in a separate section.
- **History** — timeline of generations with date, device, how many slots changed, and thumbnails of the changed slots. This is what makes history navigable instead of a table of timestamps.
- **Restore** — brings back generation N, always with a prior snapshot and confirmation that the game is closed.
- **Conflict** — both sides with date, device, and thumbnails of the diverging slots. The choice must be informed, never made over two black boxes.
- **Retention** — last 20 generations plus the first of each day for the last 30. Pruning is garbage collection: remove manifests, then delete blobs referenced by _no_ remaining manifest. Order matters.
- **Verify** — re-hash local files against the last manifest. Runs at boot and on demand.
- **Archive game** — uninstalling does not remove the `%APPDATA%` folder, so an orphaned folder looks installed forever. Do not try to truly validate installation; display "last changed N months ago" and offer to archive.

## Cross-platform

The per-OS roots are in the Ren'Py layout section. What matters: **game identity is the `save_directory`, and the path is always derived**. A game synced between Windows and a Steam Deck under Proton has the same `save_directory` on both sides despite completely different absolute paths.

In the remote manifest, always store relative POSIX-style paths, translated on restore.

ext4 is case-sensitive, NTFS is not: files differing only in case collide when restoring Linux → Windows.

Windows: `MAX_PATH` of 260 characters still bites. Use the `\\?\` prefix on file operations.

## Google OAuth

**Publish the OAuth app to production before writing the client.** In "Testing" status, refresh tokens expire after 7 days — a background sync tool that dies every week with `invalid_grant`. Personal-use apps (fewer than 100 users) do not need to complete verification; users simply click through the "unverified app" screen.

Other causes of a dead token to handle: 6 months without use invalidates automatically (realistic here — someone drops a game for a year); a maximum of 100 live refresh tokens per user per client ID, with the oldest silently invalidated.

Treat `invalid_grant` as an explicit **"reconnect account" state** in the interface, with a button. Never as a stacktrace.

Flow: installed app with PKCE and a loopback redirect (`http://127.0.0.1:<random port>`).

Refresh token storage: a file in the user data directory with `0600` permissions. A keyring protects against other users on the machine, not against code running as the user — not worth the cost of three external binaries behind ports.

Bandwidth: compare metadata `md5Checksum` before downloading; `changes.list` with `startPageToken` for deltas; resumable upload above ~5 MB.

## Desktop-specific configuration

- **SQLite path** via `:filename.basedir(:user_data, "mnemo")` in `config/runtime.exs`. The application directory is read-only in macOS `.app` bundles and AppImages.
- **Migrations run at boot**, not via Mix: `Ecto.Migrator.with_repo(Repo, &Ecto.Migrator.run(&1, :up, all: true))` before the supervision tree starts. A release has no Mix.
- **WAL is mandatory**: `journal_mode: :wal` and a generous `busy_timeout`. Several `Game.Server` processes writing in parallel produce intermittent `database is locked` with the default journal.
- **Endpoint on `127.0.0.1` with port 0.** Listening on loopback does not trigger the Windows Firewall prompt.
- Autostart at logon (never as a Windows Service — tokens and paths are per user). Closing the window hides to tray; it **must not** shut down the BEAM.

## Gettext

English msgids, `default_locale: "en"`, `pt_BR` translation. Detection via `Accept-Language` (the webview reflects the OS locale), with an explicit preference in `settings` overriding it.

Use `ngettext` from the start on the history and slots screens. Run `mix gettext.extract && mix gettext.merge priv/gettext` **before** building — Gettext is compiled, and forgetting this produces no error, just an interface half untranslated.

Do not translate user data: game name, `save_directory`, paths, device name, and hashes pass through unchanged.

## Testing

Define `Mnemo.Drive.Backend` as a behaviour with an in-memory fake implementation from day one. This gives fast, offline, deterministic tests, and allows simulating two devices as two local state instances against the same fake remote.

Build fixtures from real Ren'Py saves in `test/support/fixtures` — including a truncated `.save`, to guarantee zip validation rejects the corrupt file instead of propagating it.

Property testing with StreamData over random event sequences (write, sync, restore, play offline on both, prune). Invariants to encode:

1. No sequence of operations loses an already-confirmed generation.
2. Every restore is reversible via the generation created before it.
3. GC never deletes a blob referenced by a live manifest.
4. No snapshot containing an invalid `.save` is marked `validated`.

Sync bugs live in the improbable interleaving, which is what property testing finds and example-based testing does not.

## Phases

- **v0** — one game, scan of `%APPDATA%\RenPy`, manual sync button, OAuth end to end, SQLite storing hashes, screenshot extraction working.
- **v1** — watcher with debounce, generation protocol with conflict detection, slot grid. Usable.
- **v2** — automatic pull, history with thumbnails, restore with rollback, manual enrollment for portable installs.
- **v3** — Tauri packaging, tray, autostart, pruning, metered-network awareness.

## Do not

- Do not abstract for "other game engines". The scope is Ren'Py.
- Do not integrate SteamGridDB, IGDB, or the Steam CDN — covers come from save screenshots.
- Do not add a compression layer — everything is already compressed.
- Do not use Ash Framework.
- Do not sync the SQLite database.
- Do not build a remote backend — Drive is already the consistent coordination point. A server only if cross-user sharing ever happens.
- Do not use `phx.gen.live` / `phx.gen.context`.
- Do not use timestamps to order generations.
- Do not persist debounce transitions.
- Do not auto-merge saves.
- Do not create save directories.
