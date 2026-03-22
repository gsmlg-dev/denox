mod callback_op;
mod ts_loader;

use callback_op::{CallbackRequest, CallbackState, install_callback_global};
use deno_core::JsRuntime;
use deno_core::RuntimeOptions;
use deno_permissions::{Permissions, PermissionsContainer};
use deno_runtime::permissions::RuntimePermissionDescriptorParser;
use deno_runtime::worker::{MainWorker, WorkerOptions, WorkerServiceOptions};
use deno_runtime::BootstrapOptions;
use rustler::{Binary, Encoder, Env, LocalPid, OwnedBinary, ResourceArc, Term};
use serde::Deserialize;
use std::collections::HashMap;
use std::sync::mpsc;
use std::sync::Mutex;

rustler::atoms! {
    denox_callback,
}

// Commands sent to the dedicated V8 thread
enum Command {
    Eval {
        code: String,
        transpile: bool,
        reply: mpsc::Sender<Result<String, String>>,
    },
    EvalAsync {
        code: String,
        transpile: bool,
        reply: mpsc::Sender<Result<String, String>>,
    },
    EvalModule {
        path: String,
        reply: mpsc::Sender<Result<String, String>>,
    },
}

struct RuntimeResource {
    sender: mpsc::Sender<Command>,
    /// Receives callback requests from the V8 thread's op_elixir_call
    callback_rx: Mutex<mpsc::Receiver<CallbackRequest>>,
    /// Pending callback reply senders, keyed by callback ID.
    /// Used by callback_reply NIF to send results back to the NIF caller.
    pending_callbacks: Mutex<HashMap<u64, mpsc::Sender<Result<String, String>>>>,
    /// Elixir PID to send callback requests to (None = callbacks disabled)
    callback_pid: Option<LocalPid>,
}

// SAFETY: The RuntimeResource fields are all thread-safe:
// - mpsc::Sender is Send+Sync
// - Mutex<mpsc::Receiver> is Send+Sync
// - Mutex<HashMap> is Send+Sync
// - LocalPid is Send+Sync (just a PID identifier)
// The actual JsRuntime lives on a dedicated thread and is never shared.
unsafe impl Send for RuntimeResource {}
unsafe impl Sync for RuntimeResource {}

impl rustler::Resource for RuntimeResource {}

/// Permissions mode for the runtime, deserialized from JSON.
#[derive(Deserialize, Debug)]
#[serde(tag = "mode")]
enum PermissionsConfig {
    /// Allow everything. Logs a warning at runtime creation.
    #[serde(rename = "allow_all")]
    AllowAll,
    /// Deny everything (replaces old `sandbox: true`).
    #[serde(rename = "deny_all")]
    DenyAll,
    /// Granular permissions.
    #[serde(rename = "granular")]
    Granular {
        #[serde(default)]
        allow_read: Option<PermValue>,
        #[serde(default)]
        allow_write: Option<PermValue>,
        #[serde(default)]
        allow_net: Option<PermValue>,
        #[serde(default)]
        allow_env: Option<PermValue>,
        #[serde(default)]
        allow_run: Option<PermValue>,
        #[serde(default)]
        allow_ffi: Option<PermValue>,
        #[serde(default)]
        allow_sys: Option<PermValue>,
        #[serde(default)]
        deny_read: Option<PermValue>,
        #[serde(default)]
        deny_write: Option<PermValue>,
        #[serde(default)]
        deny_net: Option<PermValue>,
        #[serde(default)]
        deny_env: Option<PermValue>,
        #[serde(default)]
        deny_run: Option<PermValue>,
        #[serde(default)]
        deny_ffi: Option<PermValue>,
        #[serde(default)]
        deny_sys: Option<PermValue>,
    },
}

/// A permission value: true means allow/deny all, list means specific values.
#[derive(Deserialize, Debug)]
#[serde(untagged)]
enum PermValue {
    Bool(bool),
    List(Vec<String>),
}

fn perm_value_to_vec(v: &Option<PermValue>) -> Option<Vec<String>> {
    match v {
        None => None,
        Some(PermValue::Bool(true)) => Some(vec![]),
        Some(PermValue::Bool(false)) => None,
        Some(PermValue::List(items)) => Some(items.clone()),
    }
}

fn build_permissions(config: Option<&str>) -> Result<Permissions, String> {
    let config = match config {
        Some(json) if !json.is_empty() => {
            serde_json::from_str::<PermissionsConfig>(json)
                .map_err(|e| format!("Invalid permissions JSON: {}", e))?
        }
        _ => PermissionsConfig::AllowAll,
    };

    match config {
        PermissionsConfig::AllowAll => {
            log::warn!("Denox runtime created with allow-all permissions. Use granular permissions in production.");
            Ok(Permissions::allow_all())
        }
        PermissionsConfig::DenyAll => {
            Ok(Permissions::none_without_prompt())
        }
        PermissionsConfig::Granular {
            allow_read, allow_write, allow_net, allow_env,
            allow_run, allow_ffi, allow_sys,
            deny_read, deny_write, deny_net, deny_env,
            deny_run, deny_ffi, deny_sys,
        } => {
            let opts = deno_permissions::PermissionsOptions {
                allow_all: false,
                allow_read: perm_value_to_vec(&allow_read),
                allow_write: perm_value_to_vec(&allow_write),
                allow_net: perm_value_to_vec(&allow_net),
                allow_env: perm_value_to_vec(&allow_env),
                allow_run: perm_value_to_vec(&allow_run),
                allow_ffi: perm_value_to_vec(&allow_ffi),
                allow_sys: perm_value_to_vec(&allow_sys),
                deny_read: perm_value_to_vec(&deny_read),
                deny_write: perm_value_to_vec(&deny_write),
                deny_net: perm_value_to_vec(&deny_net),
                deny_env: perm_value_to_vec(&deny_env),
                deny_run: perm_value_to_vec(&deny_run),
                deny_ffi: perm_value_to_vec(&deny_ffi),
                deny_sys: perm_value_to_vec(&deny_sys),
                allow_import: None,
                prompt: false,
            };

            let fs: deno_fs::FileSystemRc = std::sync::Arc::new(deno_fs::RealFs);
            let parser = RuntimePermissionDescriptorParser::new(fs);
            Permissions::from_options(&parser, &opts)
                .map_err(|e| format!("Failed to create permissions: {}", e))
        }
    }
}

/// Transpile TypeScript to JavaScript using deno_ast (swc).
fn transpile_inline(ts_code: &str) -> Result<String, String> {
    use deno_ast::{EmitOptions, MediaType, ParseParams, SourceMapOption, TranspileOptions};

    let specifier = deno_core::url::Url::parse("file:///denox_inline.tsx")
        .map_err(|e| format!("URL parse error: {}", e))?;

    let parsed = deno_ast::parse_module(ParseParams {
        specifier,
        text: ts_code.into(),
        media_type: MediaType::Tsx,
        capture_tokens: false,
        scope_analysis: false,
        maybe_syntax: None,
    })
    .map_err(|e| format!("Transpile parse error: {}", e))?;

    let transpiled = parsed
        .transpile(
            &TranspileOptions::default(),
            &EmitOptions {
                source_map: SourceMapOption::None,
                ..Default::default()
            },
        )
        .map_err(|e| format!("Transpile error: {}", e))?;

    let source_bytes = transpiled.into_source().source;
    String::from_utf8(source_bytes).map_err(|e| format!("UTF-8 error: {}", e))
}

/// Process a V8 eval: execute code as a plain script, pump event loop,
/// resolve Promises.
fn process_eval(
    runtime: &mut JsRuntime,
    tokio_rt: &tokio::runtime::Runtime,
    code: String,
    transpile: bool,
) -> Result<String, String> {
    let js_code = if transpile {
        transpile_inline(&code)?
    } else {
        code
    };

    let result = runtime
        .execute_script("<denox>", js_code)
        .map_err(|e| format!("{}", e))?;

    // Pump the event loop to settle any pending Promises / dynamic imports
    tokio_rt
        .block_on(runtime.run_event_loop(Default::default()))
        .map_err(|e| format!("Event loop error: {}", e))?;

    // Check if result is a Promise and inspect its state
    {
        let scope = &mut runtime.handle_scope();
        let local = deno_core::v8::Local::new(scope, result);

        let promise = match deno_core::v8::Local::<deno_core::v8::Promise>::try_from(local) {
            Ok(p) => p,
            Err(_) => {
                // Not a Promise — extract value directly
                return match deno_core::serde_v8::from_v8::<serde_json::Value>(scope, local) {
                    Ok(json_val) => serde_json::to_string(&json_val)
                        .map_err(|e| format!("JSON serialization error: {}", e)),
                    Err(_) => Ok(local.to_rust_string_lossy(scope)),
                };
            }
        };

        match promise.state() {
            deno_core::v8::PromiseState::Fulfilled => {
                let value = promise.result(scope);
                match deno_core::serde_v8::from_v8::<serde_json::Value>(scope, value) {
                    Ok(json_val) => serde_json::to_string(&json_val)
                        .map_err(|e| format!("JSON serialization error: {}", e)),
                    Err(_) => Ok(value.to_rust_string_lossy(scope)),
                }
            }
            deno_core::v8::PromiseState::Rejected => {
                let value = promise.result(scope);
                let msg = value.to_rust_string_lossy(scope);
                Err(format!("Promise rejected: {}", msg))
            }
            deno_core::v8::PromiseState::Pending => {
                Err("Promise still pending after event loop completed".to_string())
            }
        }
    }
}

/// Process module evaluation: load, evaluate, and run event loop
fn process_eval_module(
    runtime: &mut JsRuntime,
    tokio_rt: &tokio::runtime::Runtime,
    path: String,
) -> Result<String, String> {
    let abs_path = std::path::Path::new(&path)
        .canonicalize()
        .map_err(|e| format!("Failed to resolve path '{}': {}", path, e))?;

    let specifier = deno_core::url::Url::from_file_path(&abs_path)
        .map_err(|_| format!("Failed to create URL from path: {}", abs_path.display()))?;

    let mod_id = tokio_rt
        .block_on(runtime.load_main_es_module(&specifier))
        .map_err(|e| format!("Module load error: {}", e))?;

    let result = runtime.mod_evaluate(mod_id);

    tokio_rt
        .block_on(runtime.run_event_loop(Default::default()))
        .map_err(|e| format!("Event loop error: {}", e))?;

    tokio_rt
        .block_on(result)
        .map_err(|e| format!("Module evaluation error: {}", e))?;

    Ok("undefined".to_string())
}

/// Process inline code as an ES module: transpile (optionally), load, evaluate,
/// and extract the `default` export as JSON.
fn process_eval_module_code(
    runtime: &mut JsRuntime,
    tokio_rt: &tokio::runtime::Runtime,
    code: String,
    transpile: bool,
    specifier: &deno_core::url::Url,
) -> Result<String, String> {
    let js_code = if transpile {
        transpile_inline(&code)?
    } else {
        code
    };

    let mod_id = tokio_rt
        .block_on(runtime.load_side_es_module_from_code(specifier, js_code))
        .map_err(|e| format!("Module load error: {}", e))?;

    let result = runtime.mod_evaluate(mod_id);

    tokio_rt
        .block_on(runtime.run_event_loop(Default::default()))
        .map_err(|e| format!("Event loop error: {}", e))?;

    tokio_rt
        .block_on(result)
        .map_err(|e| format!("Module evaluation error: {}", e))?;

    // Extract `default` export from module namespace
    let namespace = runtime
        .get_module_namespace(mod_id)
        .map_err(|e| format!("Failed to get module namespace: {}", e))?;

    let scope = &mut runtime.handle_scope();
    let ns_local = deno_core::v8::Local::new(scope, namespace);
    let key = deno_core::v8::String::new(scope, "default").unwrap();

    match ns_local.get(scope, key.into()) {
        Some(val) if !val.is_undefined() => {
            match deno_core::serde_v8::from_v8::<serde_json::Value>(scope, val) {
                Ok(json_val) => serde_json::to_string(&json_val)
                    .map_err(|e| format!("JSON serialization error: {}", e)),
                Err(_) => Ok(val.to_rust_string_lossy(scope)),
            }
        }
        _ => Ok("undefined".to_string()),
    }
}

/// Create a V8 snapshot from setup code. Returns the snapshot as a binary.
#[rustler::nif(schedule = "DirtyCpu")]
fn create_snapshot<'a>(
    env: Env<'a>,
    setup_code: String,
    transpile: bool,
) -> Result<Binary<'a>, String> {
    let js_code = if transpile {
        transpile_inline(&setup_code)?
    } else {
        setup_code
    };

    let mut runtime = deno_core::JsRuntimeForSnapshot::new(RuntimeOptions::default());

    runtime
        .execute_script("<denox_snapshot>", js_code)
        .map_err(|e| format!("Snapshot setup error: {}", e))?;

    let snapshot = runtime.snapshot();
    let bytes = snapshot.to_vec();
    let mut binary = OwnedBinary::new(bytes.len())
        .ok_or_else(|| "Failed to allocate binary for snapshot".to_string())?;
    binary.as_mut_slice().copy_from_slice(&bytes);
    Ok(binary.release(env))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn runtime_new(
    base_dir: String,
    _sandbox: bool,
    cache_dir: String,
    import_map_json: String,
    callback_pid: Option<LocalPid>,
    snapshot: Binary,
    permissions_json: String,
) -> Result<ResourceArc<RuntimeResource>, String> {
    let (tx, rx) = mpsc::channel::<Command>();

    // Parse import map JSON before moving into the thread
    let import_map: HashMap<String, String> = if import_map_json.is_empty() {
        HashMap::new()
    } else {
        serde_json::from_str(&import_map_json)
            .map_err(|e| format!("Invalid import map JSON: {}", e))?
    };

    // NOTE: Custom V8 snapshots are not compatible with MainWorker's internal
    // snapshot. MainWorker uses its own snapshot for bootstrapping the Deno
    // runtime environment. The snapshot parameter is accepted for API
    // compatibility but currently ignored. Use eval() to run initialization
    // code instead of relying on snapshots.
    let _snapshot_ignored = &snapshot;

    // Build permissions from JSON config
    let permissions_str = if permissions_json.is_empty() {
        None
    } else {
        Some(permissions_json.as_str())
    };
    let permissions = build_permissions(permissions_str)?;

    // Create callback channels
    let (callback_tx, callback_rx) = mpsc::channel::<CallbackRequest>();
    let has_callbacks = callback_pid.is_some();

    // Spawn a dedicated thread for this V8 isolate.
    std::thread::spawn(move || {
        let tokio_rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("Failed to create tokio runtime");

        let loader_cache_dir = if cache_dir.is_empty() {
            None
        } else {
            Some(cache_dir)
        };

        // Set DENO_DIR so MainWorker uses the configured cache directory for
        // npm/jsr module resolution and compilation caches.
        if let Some(ref dir) = loader_cache_dir {
            std::env::set_var("DENO_DIR", dir);
        }

        // Compute the base directory URL for module specifiers
        let base = if !base_dir.is_empty() {
            std::path::PathBuf::from(&base_dir)
                .canonicalize()
                .unwrap_or_else(|_| std::path::PathBuf::from(&base_dir))
        } else {
            std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("/"))
        };

        let main_module = deno_core::url::Url::from_directory_path(&base)
            .unwrap_or_else(|_| deno_core::url::Url::parse("file:///").unwrap());

        let mut worker = tokio_rt.block_on(async {
            let module_loader = std::rc::Rc::new(ts_loader::TsModuleLoader::new(
                loader_cache_dir,
                import_map,
            ));

            let create_web_worker_cb =
                std::sync::Arc::new(|_| panic!("Web workers are not supported in Denox"));

            let fs: deno_fs::FileSystemRc = std::sync::Arc::new(deno_fs::RealFs);
            let permission_desc_parser = std::sync::Arc::new(
                RuntimePermissionDescriptorParser::new(fs.clone()),
            );

            let services = WorkerServiceOptions {
                module_loader,
                permissions: PermissionsContainer::new(
                    permission_desc_parser,
                    permissions,
                ),
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

            let options = WorkerOptions {
                create_web_worker_cb,
                ..Default::default()
            };

            MainWorker::bootstrap_from_options(main_module.clone(), services, options)
        });

        // Keep the tokio runtime context active for the entire thread.
        // This is required for MainWorker's async ops (fetch, timers, etc.)
        // which spawn tasks on the tokio runtime.
        let _guard = tokio_rt.enter();

        // Install the Denox.callback() JS global if callbacks are enabled.
        // This uses direct V8 function bindings instead of deno_core ops,
        // because MainWorker's snapshot freezes the ops table and custom
        // ops from extensions are not exposed to JS.
        if has_callbacks {
            let state = CallbackState {
                request_tx: callback_tx,
                next_id: std::sync::atomic::AtomicU64::new(1),
            };
            install_callback_global(&mut worker.js_runtime, state);
        }

        // Module code counter for generating unique specifiers
        let mut module_counter = 0u64;

        // Receive commands from the Elixir side
        while let Ok(cmd) = rx.recv() {
            match cmd {
                Command::Eval {
                    code,
                    transpile,
                    reply,
                } => {
                    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        process_eval(&mut worker.js_runtime, &tokio_rt, code, transpile)
                    }))
                    .unwrap_or_else(|panic_val| {
                        let msg = panic_message(&panic_val);
                        Err(format!("V8 runtime panicked: {}", msg))
                    });
                    let _ = reply.send(result);
                }
                Command::EvalAsync {
                    code,
                    transpile,
                    reply,
                } => {
                    module_counter += 1;
                    // Use main_module as base so relative imports resolve correctly
                    let specifier = main_module
                        .join(&format!("denox_eval_async_{}.js", module_counter))
                        .unwrap();

                    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        process_eval_module_code(
                            &mut worker.js_runtime,
                            &tokio_rt,
                            code,
                            transpile,
                            &specifier,
                        )
                    }))
                    .unwrap_or_else(|panic_val| {
                        let msg = panic_message(&panic_val);
                        Err(format!("V8 runtime panicked: {}", msg))
                    });
                    let _ = reply.send(result);
                }
                Command::EvalModule { path, reply } => {
                    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        process_eval_module(&mut worker.js_runtime, &tokio_rt, path)
                    }))
                    .unwrap_or_else(|panic_val| {
                        let msg = panic_message(&panic_val);
                        Err(format!("V8 runtime panicked: {}", msg))
                    });
                    let _ = reply.send(result);
                }
            }
        }
    });

    Ok(ResourceArc::new(RuntimeResource {
        sender: tx,
        callback_rx: Mutex::new(callback_rx),
        pending_callbacks: Mutex::new(HashMap::new()),
        callback_pid,
    }))
}

/// Send a command to the V8 thread and wait for the result.
/// If callbacks are enabled, polls for callback requests while waiting
/// and forwards them to the Elixir callback handler process.
fn send_command(
    env: Env,
    resource: &ResourceArc<RuntimeResource>,
    cmd_fn: impl FnOnce(mpsc::Sender<Result<String, String>>) -> Command,
) -> Result<String, String> {
    let (reply_tx, reply_rx) = mpsc::channel();
    resource
        .sender
        .send(cmd_fn(reply_tx))
        .map_err(|_| "Runtime thread has shut down".to_string())?;

    // If no callback handler, just block waiting for the result
    if resource.callback_pid.is_none() {
        return reply_rx
            .recv()
            .map_err(|_| "Runtime thread died".to_string())?;
    }

    let callback_pid = resource.callback_pid.as_ref().unwrap();

    // Poll for both eval results and callback requests
    loop {
        // Check for eval result (non-blocking)
        match reply_rx.try_recv() {
            Ok(result) => return result,
            Err(mpsc::TryRecvError::Disconnected) => {
                return Err("Runtime thread died".to_string());
            }
            Err(mpsc::TryRecvError::Empty) => {}
        }

        // Check for callback requests (non-blocking)
        let maybe_req = {
            let rx = resource.callback_rx.lock().unwrap();
            rx.try_recv().ok()
        };

        if let Some(req) = maybe_req {
            handle_callback(env, resource, req, callback_pid);
        } else {
            // Brief sleep to avoid busy-waiting
            std::thread::sleep(std::time::Duration::from_micros(50));
        }
    }
}

/// Handle a single callback request: send to Elixir, wait for reply, forward to V8.
fn handle_callback(
    env: Env,
    resource: &ResourceArc<RuntimeResource>,
    req: CallbackRequest,
    pid: &LocalPid,
) {
    let callback_id = req.id;

    // Create a channel for the callback_reply NIF to send the result back
    let (cb_reply_tx, cb_reply_rx) = mpsc::channel();
    resource
        .pending_callbacks
        .lock()
        .unwrap()
        .insert(callback_id, cb_reply_tx);

    // Send {:denox_callback, resource, callback_id, name, args_json} to Elixir
    let msg = (
        denox_callback(),
        resource.clone(),
        callback_id,
        req.name.as_str(),
        req.args_json.as_str(),
    )
        .encode(env);
    let _ = env.send(pid, msg);

    // Block until the callback_reply NIF delivers the result
    let result = cb_reply_rx
        .recv()
        .unwrap_or(Err("Callback reply channel closed".to_string()));

    // Clean up
    resource
        .pending_callbacks
        .lock()
        .unwrap()
        .remove(&callback_id);

    // Send result back to the V8 thread
    let _ = req.reply_tx.send(result);
}

#[rustler::nif(schedule = "DirtyCpu")]
fn eval(
    env: Env,
    resource: ResourceArc<RuntimeResource>,
    code: String,
    transpile: bool,
) -> Result<String, String> {
    send_command(env, &resource, |reply| Command::Eval {
        code,
        transpile,
        reply,
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn eval_async(
    env: Env,
    resource: ResourceArc<RuntimeResource>,
    code: String,
    transpile: bool,
) -> Result<String, String> {
    send_command(env, &resource, |reply| Command::EvalAsync {
        code,
        transpile,
        reply,
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn eval_module(
    env: Env,
    resource: ResourceArc<RuntimeResource>,
    path: String,
) -> Result<String, String> {
    send_command(env, &resource, |reply| Command::EvalModule { path, reply })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn call_function(
    env: Env,
    resource: ResourceArc<RuntimeResource>,
    func_name: String,
    args_json: String,
) -> Result<String, String> {
    let js_code = format!("((args) => {}(...args))({})", func_name, args_json);
    send_command(env, &resource, |reply| Command::Eval {
        code: js_code,
        transpile: false,
        reply,
    })
}

/// NIF called by the Elixir callback handler to deliver a callback result.
#[rustler::nif(schedule = "DirtyCpu")]
fn callback_reply(
    resource: ResourceArc<RuntimeResource>,
    callback_id: u64,
    result_json: String,
) -> Result<(), String> {
    let tx = resource
        .pending_callbacks
        .lock()
        .unwrap()
        .remove(&callback_id)
        .ok_or_else(|| format!("Unknown callback ID: {}", callback_id))?;

    tx.send(Ok(result_json))
        .map_err(|_| "Failed to send callback reply".to_string())
}

/// NIF called by the Elixir callback handler to deliver a callback error.
#[rustler::nif(schedule = "DirtyCpu")]
fn callback_error(
    resource: ResourceArc<RuntimeResource>,
    callback_id: u64,
    error_msg: String,
) -> Result<(), String> {
    let tx = resource
        .pending_callbacks
        .lock()
        .unwrap()
        .remove(&callback_id)
        .ok_or_else(|| format!("Unknown callback ID: {}", callback_id))?;

    tx.send(Err(error_msg))
        .map_err(|_| "Failed to send callback error".to_string())
}

/// Extract a human-readable message from a panic payload.
fn panic_message(panic_val: &Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = panic_val.downcast_ref::<&str>() {
        s.to_string()
    } else if let Some(s) = panic_val.downcast_ref::<String>() {
        s.clone()
    } else {
        "unknown panic".to_string()
    }
}

// ============================================================
// Part 2: RuntimeRunResource — long-lived Deno runtime with I/O
// ============================================================

/// Default stdout buffer size (bounded channel capacity).
const DEFAULT_BUFFER_SIZE: usize = 1024;

struct RuntimeRunResource {
    stdin_tx: mpsc::Sender<String>,
    stdout_rx: Mutex<mpsc::Receiver<String>>,
    stop_tx: Mutex<Option<mpsc::Sender<()>>>,
    alive: std::sync::Arc<std::sync::atomic::AtomicBool>,
}

unsafe impl Send for RuntimeRunResource {}
unsafe impl Sync for RuntimeRunResource {}

impl rustler::Resource for RuntimeRunResource {}

/// Resolve a module specifier: npm: prefixed for scoped packages, passthrough otherwise.
fn resolve_specifier(spec: &str) -> String {
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
fn runtime_run(
    specifier: String,
    permissions_json: String,
    env_vars_json: String,
    args_json: String,
    buffer_size: usize,
) -> Result<ResourceArc<RuntimeRunResource>, String> {
    let env_vars: HashMap<String, String> = if env_vars_json.is_empty() {
        HashMap::new()
    } else {
        serde_json::from_str(&env_vars_json)
            .map_err(|e| format!("Invalid env vars JSON: {}", e))?
    };
    let args: Vec<String> = if args_json.is_empty() {
        vec![]
    } else {
        serde_json::from_str(&args_json)
            .map_err(|e| format!("Invalid args JSON: {}", e))?
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

    let (stdin_tx, stdin_rx) = mpsc::channel::<String>();
    let (stdout_tx, stdout_rx) = mpsc::sync_channel::<String>(buf_size);
    let (stop_tx, stop_rx) = mpsc::channel::<()>();
    let alive = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true));
    let alive_clone = alive.clone();

    std::thread::spawn(move || {
        let tokio_rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("Failed to create tokio runtime");

        let _guard = tokio_rt.enter();

        // Set environment variables for this runtime
        for (key, value) in env_vars.iter() {
            std::env::set_var(key, value);
        }

        let main_module_url = if resolved.starts_with("npm:") || resolved.starts_with("jsr:") {
            // For npm/jsr specifiers, use the current directory as base
            let cwd = std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("/"));
            deno_core::url::Url::from_directory_path(&cwd)
                .unwrap_or_else(|_| deno_core::url::Url::parse("file:///").unwrap())
        } else if resolved.starts_with("http://") || resolved.starts_with("https://") {
            deno_core::url::Url::parse(&resolved).unwrap()
        } else {
            // File path
            let path = std::path::Path::new(&resolved)
                .canonicalize()
                .unwrap_or_else(|_| std::path::PathBuf::from(&resolved));
            deno_core::url::Url::from_file_path(&path)
                .unwrap_or_else(|_| deno_core::url::Url::parse("file:///").unwrap())
        };

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

            let mut bootstrap = BootstrapOptions::default();
            bootstrap.args = args;

            let options = WorkerOptions {
                create_web_worker_cb,
                bootstrap,
                ..Default::default()
            };

            MainWorker::bootstrap_from_options(main_module_url.clone(), services, options)
        });

        // Install channel-based stdin/stdout bridge functions on globalThis.
        // We keep raw pointers to the channel endpoints so V8 functions can
        // access them. These MUST be reclaimed when the thread exits.
        let stdin_rx_mutex = std::sync::Arc::new(Mutex::new(stdin_rx));
        let stdin_rx_for_js = stdin_rx_mutex.clone();
        let stdout_tx_clone = stdout_tx.clone();

        let stdout_raw_ptr: *mut mpsc::SyncSender<String>;
        {
            let scope = &mut worker.js_runtime.handle_scope();
            let stdin_ptr = std::sync::Arc::into_raw(stdin_rx_for_js) as *mut std::ffi::c_void;
            let external = deno_core::v8::External::new(scope, stdin_ptr);

            let readline_fn =
                deno_core::v8::Function::builder(denox_readline_v8)
                    .data(external.into())
                    .build(scope)
                    .expect("Failed to create readline function");

            let global = scope.get_current_context().global(scope);
            let key = deno_core::v8::String::new(scope, "__denox_readline").unwrap();
            global.set(scope, key.into(), readline_fn.into());

            stdout_raw_ptr = Box::into_raw(Box::new(stdout_tx_clone));
            let stdout_external =
                deno_core::v8::External::new(scope, stdout_raw_ptr as *mut std::ffi::c_void);

            let writeline_fn =
                deno_core::v8::Function::builder(denox_writeline_v8)
                    .data(stdout_external.into())
                    .build(scope)
                    .expect("Failed to create writeline function");

            let write_key = deno_core::v8::String::new(scope, "__denox_writeline").unwrap();
            global.set(scope, write_key.into(), writeline_fn.into());
        }

        // Override console.log to send via channel, and bridge Deno.stdin
        let io_setup = r#"
            console.log = (...args) => {
                const line = args.map(a => typeof a === 'string' ? a : JSON.stringify(a)).join(' ');
                __denox_writeline(line);
            };

            // Bridge Deno.stdin.read to __denox_readline channel
            {
                const encoder = new TextEncoder();
                let pendingBuf = new Uint8Array(0);

                const stdinProxy = {
                    rid: -1,
                    read: async (buf) => {
                        if (pendingBuf.length > 0) {
                            const n = Math.min(buf.length, pendingBuf.length);
                            buf.set(pendingBuf.subarray(0, n));
                            pendingBuf = pendingBuf.subarray(n);
                            return n;
                        }
                        while (true) {
                            const line = __denox_readline();
                            if (line !== null) {
                                const data = encoder.encode(line + "\n");
                                const n = Math.min(buf.length, data.length);
                                buf.set(data.subarray(0, n));
                                if (data.length > n) {
                                    pendingBuf = data.subarray(n);
                                }
                                return n;
                            }
                            await new Promise(r => setTimeout(r, 10));
                        }
                    },
                    get readable() {
                        return new ReadableStream({
                            async pull(controller) {
                                const buf = new Uint8Array(4096);
                                const n = await stdinProxy.read(buf);
                                if (n === null) {
                                    controller.close();
                                } else {
                                    controller.enqueue(buf.subarray(0, n));
                                }
                            }
                        });
                    },
                    isTerminal() { return false; },
                    close() {},
                    setRaw() {},
                };
                Object.defineProperty(Deno, 'stdin', {
                    value: stdinProxy,
                    writable: false,
                    configurable: true,
                });
            }
        "#;
        let _ = worker.js_runtime.execute_script("<denox_run_io>", io_setup);

        // Load and run the main module
        let specifier_url = if resolved.starts_with("npm:") || resolved.starts_with("jsr:") {
            deno_core::url::Url::parse(&resolved).unwrap()
        } else {
            main_module_url.clone()
        };

        let load_result = tokio_rt.block_on(async {
            worker.execute_main_module(&specifier_url).await
        });

        if let Err(e) = load_result {
            let _ = stdout_tx.send(format!("Error loading module: {}", e));
            alive_clone.store(false, std::sync::atomic::Ordering::SeqCst);
            return;
        }

        // Run the event loop until completion or stop signal.
        // Strategy: first try a quick run to handle simple scripts that
        // complete immediately. If the event loop doesn't finish quickly,
        // enter a long-running poll loop for servers/daemons.
        let completed = tokio_rt.block_on(async {
            tokio::time::timeout(
                std::time::Duration::from_secs(1),
                worker.run_event_loop(false),
            )
            .await
        });

        match completed {
            Ok(Ok(())) => {
                // Event loop completed — script finished naturally
            }
            Ok(Err(e)) => {
                let _ = stdout_tx.send(format!("Event loop error: {}", e));
            }
            Err(_timeout) => {
                // Long-running script (server, daemon, etc.)
                // Keep running until stop signal or event loop completion.
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
                                    let _ = stdout_tx.send(format!("Event loop error: {}", e));
                                }
                                break;
                            }
                            _ = tokio::time::sleep(std::time::Duration::from_millis(100)) => {
                                continue;
                            }
                        }
                    }
                });
            }
        }

        // Reclaim the leaked stdout sender clone so the channel fully closes.
        // SAFETY: stdout_raw_ptr was created by Box::into_raw above and is
        // only accessed by V8 functions that can no longer run at this point.
        unsafe { drop(Box::from_raw(stdout_raw_ptr)); }

        // Drop the primary stdout sender to close the channel.
        drop(stdout_tx);
        alive_clone.store(false, std::sync::atomic::Ordering::SeqCst);
    });

    Ok(ResourceArc::new(RuntimeRunResource {
        stdin_tx,
        stdout_rx: Mutex::new(stdout_rx),
        stop_tx: Mutex::new(Some(stop_tx)),
        alive,
    }))
}

/// V8 function: __denox_readline() — reads a line from stdin channel
fn denox_readline_v8(
    scope: &mut deno_core::v8::HandleScope,
    args: deno_core::v8::FunctionCallbackArguments,
    mut retval: deno_core::v8::ReturnValue,
) {
    let data = args.data();
    let external =
        unsafe { deno_core::v8::Local::<deno_core::v8::External>::cast_unchecked(data) };
    let rx_ptr = external.value() as *const Mutex<mpsc::Receiver<String>>;
    // SAFETY: The Arc keeps the Mutex alive for the lifetime of the runtime
    let rx_arc = unsafe {
        std::sync::Arc::increment_strong_count(rx_ptr as *const Mutex<mpsc::Receiver<String>>);
        std::sync::Arc::from_raw(rx_ptr)
    };

    let result = rx_arc.lock().unwrap().recv_timeout(std::time::Duration::from_millis(100));
    match result {
        Ok(line) => {
            let v8_str = deno_core::v8::String::new(scope, &line).unwrap();
            retval.set(v8_str.into());
        }
        Err(_) => {
            retval.set(deno_core::v8::null(scope).into());
        }
    };
}

/// V8 function: __denox_writeline(line) — writes a line to stdout channel
fn denox_writeline_v8(
    scope: &mut deno_core::v8::HandleScope,
    args: deno_core::v8::FunctionCallbackArguments,
    _retval: deno_core::v8::ReturnValue,
) {
    let data = args.data();
    let external =
        unsafe { deno_core::v8::Local::<deno_core::v8::External>::cast_unchecked(data) };
    let tx_ptr = external.value() as *mut mpsc::SyncSender<String>;
    let tx = unsafe { &*tx_ptr };

    if args.length() > 0 {
        let val = args.get(0);
        let line = val.to_rust_string_lossy(scope);
        let _ = tx.send(line);
    }
}

/// Send a line to the runtime's stdin channel.
#[rustler::nif]
fn runtime_run_send(resource: ResourceArc<RuntimeRunResource>, data: String) -> Result<(), String> {
    resource
        .stdin_tx
        .send(data)
        .map_err(|_| "Runtime has shut down".to_string())
}

/// Block until a line is available from stdout, or return None if closed.
#[rustler::nif(schedule = "DirtyIo")]
fn runtime_run_recv(
    resource: ResourceArc<RuntimeRunResource>,
) -> Result<Option<String>, String> {
    let rx = resource.stdout_rx.lock().map_err(|_| "Lock poisoned".to_string())?;

    match rx.recv_timeout(std::time::Duration::from_secs(1)) {
        Ok(line) => Ok(Some(line)),
        Err(mpsc::RecvTimeoutError::Timeout) => Ok(None),
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            if resource.alive.load(std::sync::atomic::Ordering::SeqCst) {
                Ok(None)
            } else {
                Ok(None) // Runtime has stopped
            }
        }
    }
}

/// Signal the runtime to shut down.
#[rustler::nif]
fn runtime_run_stop(resource: ResourceArc<RuntimeRunResource>) -> Result<(), String> {
    if let Ok(mut guard) = resource.stop_tx.lock() {
        if let Some(tx) = guard.take() {
            let _ = tx.send(());
        }
    }
    Ok(())
}

/// Check if the runtime is still running.
#[rustler::nif]
fn runtime_run_alive(resource: ResourceArc<RuntimeRunResource>) -> bool {
    resource.alive.load(std::sync::atomic::Ordering::SeqCst)
}

rustler::init!("Elixir.Denox.Native", load = on_load);

fn on_load(env: Env, _info: Term) -> bool {
    let _ = env.register::<RuntimeResource>();
    env.register::<RuntimeRunResource>().is_ok()
}
