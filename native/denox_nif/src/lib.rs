mod callback_op;
mod ts_loader;

use callback_op::{CallbackRequest, CallbackState, install_callback_global};
use deno_core::JsRuntime;
use deno_core::RuntimeOptions;
use deno_permissions::{Permissions, PermissionsContainer};
use deno_runtime::permissions::RuntimePermissionDescriptorParser;
use deno_runtime::worker::{MainWorker, WorkerOptions, WorkerServiceOptions};
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
        PermissionsConfig::Granular { .. } => {
            // For granular permissions, start with deny-all and selectively allow.
            // Full granular support requires parsing each field into the proper
            // UnaryPermission types, which is complex. For now, we support
            // AllowAll and DenyAll, with granular as a future enhancement.
            // TODO: Implement full granular permission parsing
            Ok(Permissions::none_without_prompt())
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

rustler::init!("Elixir.Denox.Native", load = on_load);

fn on_load(env: Env, _info: Term) -> bool {
    env.register::<RuntimeResource>().is_ok()
}
