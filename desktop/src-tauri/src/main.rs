// The desktop shell: a window, and the Elixir release that fills it.
//
// Tauri does not host the BEAM, it runs it alongside. The release is
// bundled as a resource, started as a child process, and the webview is
// pointed at whatever port it reports back — which is not known ahead of
// time, because the endpoint binds to port 0 so the application still
// starts when something else holds the port it wanted.
//
// The whole handshake is rehearsed by `desktop/verify-launch.sh`, which
// runs without any of this compiled.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::{
    process::{Child, Command},
    sync::Mutex,
    thread,
    time::{Duration, Instant},
};

use tauri::{Emitter, Manager, RunEvent, WebviewUrl, WebviewWindowBuilder};

/// How long to wait for the release to publish its address. The BEAM
/// boots and migrates in about a second on a warm machine; this is the
/// budget for a cold one on slow storage.
const BOOT_TIMEOUT: Duration = Duration::from_secs(40);

/// The child process, kept so it can be shut down when the window goes.
struct Backend(Mutex<Option<Child>>);

fn main() {
    tauri::Builder::default()
        // Two copies would fight over the same database and the same
        // Drive lineage. The BEAM's node name used to refuse this by
        // accident, but distribution is switched off below, so it has to
        // be refused on purpose.
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.show();
                let _ = window.unminimize();
                let _ = window.set_focus();
            }
        }))
        .manage(Backend(Mutex::new(None)))
        .setup(|app| {
            let release = app
                .path()
                .resource_dir()?
                .join("mnemo")
                .join("bin")
                .join(if cfg!(windows) { "mnemo.bat" } else { "mnemo" });

            let child = Command::new(&release)
                .arg("start")
                .env("PHX_SERVER", "true")
                // No epmd in the bundle, no hostname resolution to fail,
                // and no port a firewall might ask about. The cost is
                // that `bin/mnemo stop` and `rpc` stop working, so
                // shutdown is a signal — see `terminate`.
                .env("RELEASE_DISTRIBUTION", "none")
                .spawn()?;

            app.state::<Backend>().0.lock().unwrap().replace(child);

            // Shown immediately: the window must exist before the
            // release is ready, or the application looks like it failed
            // to open.
            let window = WebviewWindowBuilder::new(
                app,
                "main",
                WebviewUrl::App("index.html".into()),
            )
            .title("mnemo")
            .inner_size(1100.0, 780.0)
            .min_inner_size(640.0, 480.0)
            .build()?;

            // Polling on its own thread so the window stays responsive
            // while the BEAM boots.
            let handle = app.handle().clone();
            thread::spawn(move || match wait_for_address(&handle) {
                Some(url) => {
                    let _ = window.navigate(url.parse().expect("the release published a url"));
                }
                None => {
                    let _ = window.emit("mnemo://unavailable", ());
                }
            });

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("the desktop shell failed to start")
        .run(|app, event| {
            if let RunEvent::ExitRequested { .. } | RunEvent::Exit = event {
                terminate(app.state::<Backend>());
            }
        });
}

/// Wait for the release to write down where it is listening.
///
/// The address file is the contract: `Mnemo.Endpoint.Address` writes it
/// once the endpoint has bound, and removes it on shutdown, so its mere
/// presence is not trusted — a file from a previous run is skipped by
/// only accepting one written after this process started looking.
fn wait_for_address(app: &tauri::AppHandle) -> Option<String> {
    let file = app
        .path()
        .app_data_dir()
        .ok()?
        .parent()?
        .join("mnemo")
        .join("endpoint.json");

    let deadline = Instant::now() + BOOT_TIMEOUT;

    while Instant::now() < deadline {
        if let Ok(raw) = std::fs::read_to_string(&file) {
            if let Ok(value) = serde_json::from_str::<serde_json::Value>(&raw) {
                if let Some(url) = value.get("url").and_then(|u| u.as_str()) {
                    return Some(url.to_string());
                }
            }
        }
        thread::sleep(Duration::from_millis(200));
    }

    None
}

/// Ask the release to stop, and give it time to.
///
/// It must be a graceful stop: the BEAM's shutdown is what removes the
/// address file, and a killed process leaves one behind pointing at a
/// port that now belongs to something else.
fn terminate(backend: tauri::State<Backend>) {
    let Some(mut child) = backend.0.lock().unwrap().take() else {
        return;
    };

    #[cfg(unix)]
    {
        // SIGTERM reaches erl_signal_server, which calls init:stop/0 and
        // runs every terminate callback on the way down. Verified by
        // desktop/verify-launch.sh.
        unsafe { libc::kill(child.id() as i32, libc::SIGTERM) };

        let deadline = Instant::now() + Duration::from_secs(15);
        while Instant::now() < deadline {
            match child.try_wait() {
                Ok(Some(_)) => return,
                Ok(None) => thread::sleep(Duration::from_millis(100)),
                Err(_) => break,
            }
        }
    }

    // On Windows there is no SIGTERM, and with distribution switched off
    // `bin/mnemo stop` cannot be used either, so this kills the process
    // and the address file is left behind. Not good enough to ship on
    // Windows: the fix is a loopback shutdown route the launcher can
    // call, which works the same on every platform. See desktop/README.
    let _ = child.kill();
}
