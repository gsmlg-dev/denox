use crate::build_permissions;
use crate::ts_loader;
use deno_permissions::PermissionsContainer;
use deno_runtime::permissions::RuntimePermissionDescriptorParser;
use deno_runtime::worker::{MainWorker, WorkerOptions, WorkerServiceOptions};
use deno_runtime::BootstrapOptions;
use rustler::ResourceArc;
use std::collections::HashMap;
use std::sync::mpsc;
use std::sync::Mutex;

/// Default stdout channel capacity in lines (bounded channel capacity).
/// Used when buffer_size == 0 (i.e., the caller did not specify a value).
const DEFAULT_BUFFER_SIZE: usize = 1024;

pub struct RuntimeRunResource {
    stdin_tx: mpsc::Sender<String>,
    stdout_rx: Mutex<mpsc::Receiver<String>>,
    stop_tx: Mutex<Option<mpsc::Sender<()>>>,
    alive: std::sync::Arc<std::sync::atomic::AtomicBool>,
}

// SAFETY: All fields are thread-safe:
// - mpsc::Sender is Send+Sync
// - Mutex<mpsc::Receiver> and Mutex<Option<mpsc::Sender>> are Send+Sync
// - Arc<AtomicBool> is Send+Sync
// The MainWorker lives on a dedicated thread and is never shared.
unsafe impl Send for RuntimeRunResource {}
unsafe impl Sync for RuntimeRunResource {}

impl rustler::Resource for RuntimeRunResource {}

/// Resolve a module specifier: npm: prefixed for scoped packages, passthrough otherwise.
pub fn resolve_specifier(spec: &str) -> String {
    if spec.starts_with("npm:")
        || spec.starts_with("jsr:")
        || spec.starts_with("http://")
        || spec.starts_with("https://")
        || spec.starts_with("file://")
    {
        spec.to_string()
    } else if spec.starts_with('@') {
        format!("npm:{}", spec)
    } else {
        spec.to_string()
    }
}

/// Create a long-lived runtime that loads and runs a module.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn runtime_run(
    specifier: String,
    permissions_json: String,
    env_vars_json: String,
    args_json: String,
    buffer_size: usize,
) -> Result<ResourceArc<RuntimeRunResource>, String> {
    let env_vars: HashMap<String, String> = if env_vars_json.is_empty() {
        HashMap::new()
    } else {
        serde_json::from_str(&env_vars_json).map_err(|e| format!("Invalid env vars JSON: {}", e))?
    };
    let args: Vec<String> = if args_json.is_empty() {
        vec![]
    } else {
        serde_json::from_str(&args_json).map_err(|e| format!("Invalid args JSON: {}", e))?
    };
    let resolved = resolve_specifier(&specifier);

    let permissions_str = if permissions_json.is_empty() {
        None
    } else {
        Some(permissions_json.as_str())
    };
    let permissions = build_permissions(permissions_str)?;

    let buf_size = if buffer_size == 0 {
        DEFAULT_BUFFER_SIZE
    } else {
        buffer_size
    };

    // Create OS pipe pairs for stdin/stdout bridging.
    // Deno reads from stdin_deno_read, Elixir writes to stdin_deno_write.
    // Deno writes to stdout_deno_write, Elixir reads from stdout_deno_read.
    let (stdin_deno_read, stdin_deno_write) =
        deno_io::pipe().map_err(|e| format!("Failed to create stdin pipe: {}", e))?;
    let (stdout_deno_read, stdout_deno_write) =
        deno_io::pipe().map_err(|e| format!("Failed to create stdout pipe: {}", e))?;

    let (stdin_tx, stdin_rx) = mpsc::channel::<String>();
    let (stdout_tx, stdout_rx) = mpsc::sync_channel::<String>(buf_size);
    let (stop_tx, stop_rx) = mpsc::channel::<()>();
    let alive = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true));
    let alive_clone = alive.clone();
    let alive_writer = alive.clone();
    let alive_reader = alive.clone();

    // Bridge thread: stdin mpsc channel → stdin pipe (Elixir → Deno)
    let mut stdin_pipe_writer = stdin_deno_write;
    std::thread::spawn(move || {
        use std::io::Write;
        while alive_writer.load(std::sync::atomic::Ordering::SeqCst) {
            match stdin_rx.recv_timeout(std::time::Duration::from_millis(100)) {
                Ok(line) => {
                    if stdin_pipe_writer.write_all(line.as_bytes()).is_err() {
                        break;
                    }
                    if !line.ends_with('\n')
                        && stdin_pipe_writer.write_all(b"\n").is_err()
                    {
                        break;
                    }
                    if stdin_pipe_writer.flush().is_err() {
                        break;
                    }
                }
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
        }
    });

    // Bridge thread: stdout pipe → stdout mpsc channel (Deno → Elixir)
    let mut stdout_pipe_reader = stdout_deno_read;
    std::thread::spawn(move || {
        use std::io::{BufRead, BufReader};
        let reader = BufReader::new(&mut stdout_pipe_reader);
        for line_result in reader.lines() {
            match line_result {
                Ok(line) => {
                    if stdout_tx.send(line).is_err() {
                        break;
                    }
                }
                Err(e) => {
                    // Only log if it's not a normal pipe close (broken pipe / EOF).
                    // Broken pipe errors are expected when the runtime exits.
                    let kind = e.kind();
                    if kind != std::io::ErrorKind::BrokenPipe
                        && kind != std::io::ErrorKind::UnexpectedEof
                    {
                        eprintln!("[denox] stdout pipe read error: {e}");
                    }
                    break;
                }
            }
        }
        // Pipe closed — mark as not alive if the event loop thread hasn't already
        alive_reader.store(false, std::sync::atomic::Ordering::SeqCst);
    });

    std::thread::spawn(move || {
        // Wrap the entire thread body so that panics are caught and
        // the alive flag is always set to false on exit.
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let tokio_rt = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(rt) => rt,
                Err(e) => {
                    eprintln!("Failed to create tokio runtime: {}", e);
                    return;
                }
            };

            let _guard = tokio_rt.enter();

            // Set environment variables for this runtime.
            // NOTE: set_var modifies the process-wide environment, which can race
            // when multiple runtime_run instances start concurrently with different
            // env maps. This is a known limitation — Deno's MainWorker reads env
            // vars from the process environment via Deno.env.get().
            for (key, value) in env_vars.iter() {
                std::env::set_var(key, value);
            }

            let fallback_url = deno_core::url::Url::parse("file:///").expect("static URL parse");

            let main_module_url = if resolved.starts_with("npm:") || resolved.starts_with("jsr:") {
                let cwd = std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("/"));
                deno_core::url::Url::from_directory_path(&cwd)
                    .unwrap_or_else(|_| fallback_url.clone())
            } else if resolved.starts_with("http://") || resolved.starts_with("https://") {
                match deno_core::url::Url::parse(&resolved) {
                    Ok(url) => url,
                    Err(e) => {
                        eprintln!("Invalid URL '{}': {}", resolved, e);
                        return;
                    }
                }
            } else {
                let path = std::path::Path::new(&resolved)
                    .canonicalize()
                    .unwrap_or_else(|_| std::path::PathBuf::from(&resolved));
                deno_core::url::Url::from_file_path(&path).unwrap_or_else(|_| fallback_url.clone())
            };

            // Configure MainWorker with piped stdin/stdout via deno_io
            let mut worker = tokio_rt.block_on(async {
                let module_loader =
                    std::rc::Rc::new(ts_loader::TsModuleLoader::new(None, HashMap::new()));

                let create_web_worker_cb =
                    std::sync::Arc::new(|_| panic!("Web workers are not supported in Denox"));

                let fs: deno_fs::FileSystemRc = std::sync::Arc::new(deno_fs::RealFs);
                let permission_desc_parser =
                    std::sync::Arc::new(RuntimePermissionDescriptorParser::new(fs.clone()));

                let services = WorkerServiceOptions {
                    module_loader,
                    permissions: PermissionsContainer::new(permission_desc_parser, permissions),
                    blob_store: Default::default(),
                    broadcast_channel: Default::default(),
                    feature_checker: Default::default(),
                    fs: fs.clone(),
                    node_services: None,
                    npm_process_state_provider: None,
                    root_cert_store_provider: None,
                    shared_array_buffer_store: None,
                    compiled_wasm_module_store: None,
                    v8_code_cache: None,
                };

                let bootstrap = BootstrapOptions {
                    args,
                    ..Default::default()
                };

                let options = WorkerOptions {
                    create_web_worker_cb,
                    bootstrap,
                    stdio: deno_io::Stdio {
                        stdin: deno_io::StdioPipe::file(stdin_deno_read),
                        stdout: deno_io::StdioPipe::file(stdout_deno_write),
                        stderr: deno_io::StdioPipe::inherit(),
                    },
                    ..Default::default()
                };

                MainWorker::bootstrap_from_options(main_module_url.clone(), services, options)
            });

            // Load and run the main module
            let specifier_url = if resolved.starts_with("npm:") || resolved.starts_with("jsr:") {
                match deno_core::url::Url::parse(&resolved) {
                    Ok(url) => url,
                    Err(e) => {
                        eprintln!("Invalid specifier URL '{}': {}", resolved, e);
                        return;
                    }
                }
            } else {
                main_module_url.clone()
            };

            let load_result =
                tokio_rt.block_on(async { worker.execute_main_module(&specifier_url).await });

            if let Err(e) = load_result {
                eprintln!("Error loading module: {}", e);
                return;
            }

            // Run the event loop until completion or stop signal.
            // Polls the stop channel every 100ms so runtime_run_stop() is
            // respected promptly for long-running scripts (servers, daemons).
            // For quick scripts the biased select picks up completion immediately
            // without waiting for the sleep.
            tokio_rt.block_on(async {
                let event_loop = worker.run_event_loop(false);
                tokio::pin!(event_loop);

                loop {
                    match stop_rx.try_recv() {
                        Ok(()) | Err(mpsc::TryRecvError::Disconnected) => break,
                        Err(mpsc::TryRecvError::Empty) => {}
                    }

                    tokio::select! {
                        biased;
                        result = &mut event_loop => {
                            if let Err(e) = result {
                                // Broken pipe is expected when the stdout consumer
                                // disconnects (e.g. Enum.take/2 on a stream).
                                let msg = e.to_string();
                                if !msg.contains("Broken pipe") && !msg.contains("os error 32") {
                                    eprintln!("Event loop error: {}", e);
                                }
                            }
                            break;
                        }
                        _ = tokio::time::sleep(std::time::Duration::from_millis(100)) => {}
                    }
                }
            });
        }));

        if let Err(panic_info) = result {
            let msg = if let Some(s) = panic_info.downcast_ref::<&str>() {
                s.to_string()
            } else if let Some(s) = panic_info.downcast_ref::<String>() {
                s.clone()
            } else {
                "unknown panic".to_string()
            };
            eprintln!("Denox runtime_run thread panicked: {}", msg);
        }

        // Always mark as not alive on thread exit, regardless of success or panic
        alive_clone.store(false, std::sync::atomic::Ordering::SeqCst);
    });

    Ok(ResourceArc::new(RuntimeRunResource {
        stdin_tx,
        stdout_rx: Mutex::new(stdout_rx),
        stop_tx: Mutex::new(Some(stop_tx)),
        alive,
    }))
}

/// Send a line to the runtime's stdin channel.
#[rustler::nif]
pub fn runtime_run_send(
    resource: ResourceArc<RuntimeRunResource>,
    data: String,
) -> Result<(), String> {
    resource
        .stdin_tx
        .send(data)
        .map_err(|_| "Runtime has shut down".to_string())
}

/// Block until a line is available from stdout, or return None if closed.
#[rustler::nif(schedule = "DirtyIo")]
pub fn runtime_run_recv(
    resource: ResourceArc<RuntimeRunResource>,
) -> Result<Option<String>, String> {
    let rx = resource
        .stdout_rx
        .lock()
        .map_err(|_| "Lock poisoned".to_string())?;

    match rx.recv_timeout(std::time::Duration::from_secs(1)) {
        Ok(line) => Ok(Some(line)),
        Err(mpsc::RecvTimeoutError::Timeout) | Err(mpsc::RecvTimeoutError::Disconnected) => {
            Ok(None)
        }
    }
}

/// Signal the runtime to shut down.
#[rustler::nif]
pub fn runtime_run_stop(resource: ResourceArc<RuntimeRunResource>) -> Result<(), String> {
    if let Ok(mut guard) = resource.stop_tx.lock() {
        if let Some(tx) = guard.take() {
            let _ = tx.send(());
        }
    }
    Ok(())
}

/// Check if the runtime is still running.
#[rustler::nif]
pub fn runtime_run_alive(resource: ResourceArc<RuntimeRunResource>) -> bool {
    resource.alive.load(std::sync::atomic::Ordering::SeqCst)
}
