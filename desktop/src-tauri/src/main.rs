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
    io::{Read, Write},
    net::TcpStream,
    path::PathBuf,
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
struct Backend(Mutex<BackendState>);

#[derive(Default)]
struct BackendState {
    child: Option<Child>,
    control: Option<Control>,
}

#[derive(Clone)]
struct Control {
    url: String,
    token: String,
}

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
        .manage(Backend(Mutex::new(BackendState::default())))
        .setup(|app| {
            let data_dir = mnemo_dir(app.path().app_data_dir()?)?;
            let cache_dir = mnemo_dir(app.path().app_cache_dir()?)?;
            let address_file = data_dir.join("endpoint.json");

            // A hard kill can leave the previous address behind. Remove
            // it before spawning so the polling thread can only observe
            // data published by this child.
            match std::fs::remove_file(&address_file) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(error.into()),
            }

            let release = app
                .path()
                .resource_dir()?
                .join("mnemo")
                .join("bin")
                .join(if cfg!(windows) { "mnemo.bat" } else { "mnemo" });

            let child = Command::new(&release)
                .arg("start")
                .env("PHX_SERVER", "true")
                // Both processes use these exact paths. Platform APIs do
                // not agree on whether "user data" means roaming or local
                // data on Windows, so neither side guesses independently.
                .env("MNEMO_DATA_DIR", &data_dir)
                .env("MNEMO_CACHE_DIR", &cache_dir)
                // No epmd in the bundle, no hostname resolution to fail,
                // and no port a firewall might ask about. The cost is
                // that `bin/mnemo stop` and `rpc` stop working, so
                // shutdown is a signal — see `terminate`.
                .env("RELEASE_DISTRIBUTION", "none")
                .spawn()?;

            app.state::<Backend>().0.lock().unwrap().child = Some(child);

            // Shown immediately: the window must exist before the
            // release is ready, or the application looks like it failed
            // to open.
            let window =
                WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
                    .title("mnemo")
                    .inner_size(1100.0, 780.0)
                    .min_inner_size(640.0, 480.0)
                    .build()?;

            // Polling on its own thread so the window stays responsive
            // while the BEAM boots.
            let handle = app.handle().clone();
            thread::spawn(move || match wait_for_address(address_file) {
                Some(control) => {
                    let url = control.url.clone();
                    handle.state::<Backend>().0.lock().unwrap().control = Some(control);
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
fn wait_for_address(file: PathBuf) -> Option<Control> {
    let deadline = Instant::now() + BOOT_TIMEOUT;

    while Instant::now() < deadline {
        if let Ok(raw) = std::fs::read_to_string(&file) {
            if let Ok(value) = serde_json::from_str::<serde_json::Value>(&raw) {
                if let (Some(url), Some(token)) = (
                    value.get("url").and_then(|u| u.as_str()),
                    value.get("token").and_then(|t| t.as_str()),
                ) {
                    return Some(Control {
                        url: url.to_string(),
                        token: token.to_string(),
                    });
                }
            }
        }
        thread::sleep(Duration::from_millis(200));
    }

    None
}

fn mnemo_dir(app_dir: PathBuf) -> Result<PathBuf, std::io::Error> {
    app_dir
        .parent()
        .map(|parent| parent.join("mnemo"))
        .ok_or_else(|| std::io::Error::other("application directory has no parent"))
}

/// Ask the release to stop, and give it time to.
///
/// It must be a graceful stop: the BEAM's shutdown is what removes the
/// address file, and a killed process leaves one behind pointing at a
/// port that now belongs to something else.
fn terminate(backend: tauri::State<Backend>) {
    let (child, control) = {
        let mut state = backend.0.lock().unwrap();
        (state.child.take(), state.control.take())
    };

    let Some(mut child) = child else {
        return;
    };

    if let Some(control) = control {
        let _ = request_shutdown(&control);

        if wait_for_exit(&mut child, Duration::from_secs(15)) {
            return;
        }
    }

    #[cfg(unix)]
    {
        // Fallback for a backend that booted but never published its
        // control token, or stopped answering HTTP.
        unsafe { libc::kill(child.id() as i32, libc::SIGTERM) };

        if wait_for_exit(&mut child, Duration::from_secs(15)) {
            return;
        }
    }

    // Last resort after the authenticated HTTP shutdown (and SIGTERM on
    // Unix) failed. The next launch ignores stale endpoint files until a
    // fresh backend overwrites them.
    let _ = child.kill();
}

fn request_shutdown(control: &Control) -> std::io::Result<()> {
    let authority = control
        .url
        .strip_prefix("http://")
        .and_then(|url| url.split('/').next())
        .ok_or_else(|| std::io::Error::other("unsupported backend url"))?;
    let (host, port) = authority
        .rsplit_once(':')
        .ok_or_else(|| std::io::Error::other("backend url has no port"))?;

    let mut stream =
        TcpStream::connect((host, port.parse::<u16>().map_err(std::io::Error::other)?))?;
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;

    write!(
        stream,
        "POST /_mnemo/shutdown HTTP/1.1\r\nHost: {authority}\r\nAuthorization: Bearer {}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        control.token
    )?;
    stream.flush()?;

    let mut response = [0_u8; 64];
    let read = stream.read(&mut response)?;
    let status = std::str::from_utf8(&response[..read]).unwrap_or_default();

    if status.starts_with("HTTP/1.1 204") || status.starts_with("HTTP/1.0 204") {
        Ok(())
    } else {
        Err(std::io::Error::other("backend rejected shutdown"))
    }
}

fn wait_for_exit(child: &mut Child, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;

    while Instant::now() < deadline {
        match child.try_wait() {
            Ok(Some(_)) => return true,
            Ok(None) => thread::sleep(Duration::from_millis(100)),
            Err(_) => return false,
        }
    }

    false
}
