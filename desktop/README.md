# Desktop shell

Tauri window + tray around the Elixir release. Tauri does not host the
BEAM; it runs the release as a child process and points a webview at the
port that release reports back.

```
window opens
  → the shell starts bin/mnemo start as a child
  → the BEAM boots, migrates, binds port 0
  → Mnemo.Endpoint.Address writes <user_data>/mnemo/endpoint.json
  → the shell polls for that file and navigates the webview to its url
  → on exit, authenticated loopback shutdown; the BEAM removes the address
```

## What is proven and what is not

`verify-launch.sh` performs that whole handshake against a real release,
with no Rust involved, and it passes:

```
$ desktop/verify-launch.sh
  ok    address published after 1s
  ok    url: http://127.0.0.1:39721
  ok    port was assigned by the OS, not hard-coded
  ok    / -> 200
  ok    /enroll -> 200
  ok    /settings -> 200
  ok    database created and migrated at boot
  ok    authenticated shutdown accepted
  ok    shut down gracefully after 1s
  ok    address file removed on shutdown
```

Run it after any change to the endpoint, the address file, or the
release configuration — it catches the packaging failures that the test
suite cannot see.

## Building it

Nothing here is needed to run mnemo itself — only to package it.

```sh
# Rust, once
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# System libraries, once (Debian/Ubuntu/Mint)
sudo apt install libwebkit2gtk-4.1-dev build-essential curl wget file \
  libxdo-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev

# The Tauri CLI
cargo install tauri-cli --version '^2'

# Icons: the bundler needs them and icons/ is empty
cargo tauri icon ../../priv/static/images/logo.svg
```

Then, from the repository root — the release has to exist first, because
it is bundled as a resource:

```sh
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release --overwrite
cd desktop/src-tauri
cargo tauri build --config tauri.linux.conf.json
```

On Windows, run the same Phoenix commands in a native Windows shell and
finish with:

```powershell
cd desktop/src-tauri
cargo tauri build --config tauri.windows.conf.json
```

The native outputs are AppImage + deb on Linux and an NSIS setup
executable on Windows.

## Publishing GitHub Releases

Pushing a semantic version tag runs `.github/workflows/release.yml`:

```sh
git tag v0.1.0
git push origin v0.1.0
```

GitHub builds the Elixir release and Tauri bundle independently on
Ubuntu and Windows, then publishes all three installers plus
`SHA256SUMS` in one GitHub Release. The tag must match the versions in
`mix.exs`, `src-tauri/Cargo.toml`, and `src-tauri/tauri.conf.json`.

## Decisions worth knowing before changing them

**`RELEASE_DISTRIBUTION=none`.** Keeps epmd out of the bundle, along with
its hostname resolution and its listening socket. The cost is that
`bin/mnemo stop`, `rpc` and `remote` all stop working, since they are
implemented as distributed calls. Shutdown therefore uses the local
authenticated HTTP control route.

**Single instance is enforced by the plugin, not by luck.** Two copies
would fight over one database and one Drive lineage. The BEAM's node name
used to refuse a second copy as a side effect; switching distribution off
removed that, so it is now the plugin's job.

**The address file is a contract, not a convenience.** It is how the
window learns the port, and `Mnemo.Endpoint.Address` removes it on
shutdown so a stale one never points at a port something else has taken.
The file carries a fresh random token. The launcher presents it to the
loopback-only shutdown route and waits for a graceful stop; SIGTERM on
Unix and process termination are fallbacks.

**Tauri owns the desktop paths.** It passes `MNEMO_DATA_DIR` and
`MNEMO_CACHE_DIR` to the release so Windows roaming/local-data
conventions cannot make the launcher and backend look in different
directories.

## Cross-compilation is not possible

A release embeds ERTS, which is a native binary — what is in `_build` now
runs on Linux x86-64 and nowhere else, `bin/mnemo.bat` notwithstanding.
Each target needs its own build machine. The release workflow currently
uses one Ubuntu runner and one Windows runner.
