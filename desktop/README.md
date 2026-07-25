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
  → on exit, SIGTERM; the BEAM removes the address on its way down
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
  ok    shut down on SIGTERM after 2s
  ok    address file removed on shutdown
```

Run it after any change to the endpoint, the address file, or the
release configuration — it catches the packaging failures that the test
suite cannot see.

**`src-tauri/` has never been compiled.** No Rust toolchain and no
webkit2gtk were available on the machine it was written on, so the Rust,
the manifest and the Tauri configuration are unverified against a real
build: expect to adjust schema details for whichever Tauri version you
install. The launch sequence it implements is the one the script above
proves; the parts to distrust are the API calls, not the design.

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
cd desktop/src-tauri && cargo tauri build
```

## Decisions worth knowing before changing them

**`RELEASE_DISTRIBUTION=none`.** Keeps epmd out of the bundle, along with
its hostname resolution and its listening socket. The cost is that
`bin/mnemo stop`, `rpc` and `remote` all stop working, since they are
implemented as distributed calls. Shutdown is therefore a signal.

**Single instance is enforced by the plugin, not by luck.** Two copies
would fight over one database and one Drive lineage. The BEAM's node name
used to refuse a second copy as a side effect; switching distribution off
removed that, so it is now the plugin's job.

**The address file is a contract, not a convenience.** It is how the
window learns the port, and `Mnemo.Endpoint.Address` removes it on
shutdown so a stale one never points at a port something else has taken.
Anything that kills the BEAM instead of stopping it breaks that.

## Known gap: shutdown on Windows

Windows has no SIGTERM, and with distribution off `bin/mnemo stop` is not
available either, so `terminate` falls back to killing the process — which
leaves the address file behind.

The fix that works everywhere is a loopback shutdown route in the
application: the launcher already knows the url, so it can ask the BEAM
to stop over HTTP and get the same graceful path SIGTERM gives. It should
carry a token written into the address file, so that a web page which
guessed the port cannot stop the application.

Not done, because Linux does not need it and shipping an unverified
Windows path is worse than naming the gap. Do it before the first Windows
build.

## Cross-compilation is not possible

A release embeds ERTS, which is a native binary — what is in `_build` now
runs on Linux x86-64 and nowhere else, `bin/mnemo.bat` notwithstanding.
Each target needs its own build machine: three CI runners, and macOS
splits again into Intel and Apple Silicon.
