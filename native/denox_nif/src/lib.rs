mod callback_op;
mod timer_op;
mod ts_loader;

use callback_op::{CallbackRequest, CallbackState};
use deno_core::JsRuntime;
use deno_core::RuntimeOptions;
use rustler::{Binary, Encoder, Env, LocalPid, OwnedBinary, ResourceArc, Term};
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

/// Transpile TypeScript to JavaScript using deno_ast (swc).
fn transpile_inline(ts_code: &str) -> Result<String, String> {
    use deno_ast::{
        EmitOptions, MediaType, ParseParams, SourceMapOption, TranspileModuleOptions,
        TranspileOptions,
    };

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
            &TranspileModuleOptions::default(),
            &EmitOptions {
                source_map: SourceMapOption::None,
                ..Default::default()
            },
        )
        .map_err(|e| format!("Transpile error: {}", e))?;

    Ok(transpiled.into_source().text)
}

/// Process a V8 eval: execute code, pump event loop, resolve Promises.
///
/// When `wrap_async` is true, wraps code in `(async () => { ... })()` so that
/// `await` and `return` work at the top level. When false, code runs as a
/// plain script — simple expressions like `1 + 2` work without `return`.
fn process_eval(
    runtime: &mut JsRuntime,
    tokio_rt: &tokio::runtime::Runtime,
    code: String,
    transpile: bool,
    wrap_async: bool,
    script_name: &'static str,
) -> Result<String, String> {
    let js_code = if transpile {
        transpile_inline(&code)?
    } else {
        code
    };

    let js_code = if wrap_async {
        format!("(async () => {{ {} }})()", js_code)
    } else {
        js_code
    };

    let result = runtime
        .execute_script(script_name, js_code)
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
    sandbox: bool,
    cache_dir: String,
    import_map_json: String,
    callback_pid: Option<LocalPid>,
    snapshot: Binary,
) -> Result<ResourceArc<RuntimeResource>, String> {
    let (tx, rx) = mpsc::channel::<Command>();

    // Parse import map JSON before moving into the thread
    let import_map: HashMap<String, String> = if import_map_json.is_empty() {
        HashMap::new()
    } else {
        serde_json::from_str(&import_map_json)
            .map_err(|e| format!("Invalid import map JSON: {}", e))?
    };

    // Leak snapshot bytes to get 'static lifetime (V8 requires it)
    let startup_snapshot: Option<&'static [u8]> = if snapshot.is_empty() {
        None
    } else {
        let bytes = snapshot.as_slice().to_vec();
        Some(Box::leak(bytes.into_boxed_slice()))
    };

    // Create callback channels
    let (callback_tx, callback_rx) = mpsc::channel::<CallbackRequest>();
    let has_callbacks = callback_pid.is_some();

    // Spawn a dedicated thread for this V8 isolate.
    std::thread::spawn(move || {
        let tokio_rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("Failed to create tokio runtime");

        // Compute the async script name using the base_dir (or cwd fallback).
        let base = if !base_dir.is_empty() {
            std::path::PathBuf::from(&base_dir)
                .canonicalize()
                .unwrap_or_else(|_| std::path::PathBuf::from(&base_dir))
        } else {
            std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("/"))
        };
        let script_url = deno_core::url::Url::from_file_path(base.join("__denox_async.js"))
            .unwrap_or_else(|_| deno_core::url::Url::parse("file:///denox_async.js").unwrap());
        let script_name: &'static str = Box::leak(script_url.to_string().into_boxed_str());

        let loader_cache_dir = if cache_dir.is_empty() {
            None
        } else {
            Some(cache_dir)
        };

        let mut runtime = tokio_rt.block_on(async {
            let mut opts = RuntimeOptions {
                module_loader: Some(std::rc::Rc::new(ts_loader::TsModuleLoader::new(
                    loader_cache_dir,
                    import_map,
                ))),
                startup_snapshot,
                ..Default::default()
            };

            // Register the timer extension for real setTimeout/setInterval
            opts.extensions
                .push(timer_op::denox_timer_ext::init_ops());

            // Register the callback extension if callbacks are enabled
            if has_callbacks {
                opts.extensions
                    .push(callback_op::denox_callback_ext::init_ops());
            }

            // In sandbox mode, strip all extensions to disable fs/net/timer ops
            if sandbox {
                opts.extensions = vec![];
            }

            JsRuntime::new(opts)
        });

        // Polyfill setTimeout/setInterval/clearTimeout/clearInterval
        // Uses the native op_sleep async op for real ms-accurate delays.
        let _ = runtime.execute_script(
            "<denox_timer_polyfill>",
            r#"
            (function() {
                var _nextId = 1;
                var _timers = {};

                globalThis.setTimeout = function(callback, delay) {
                    var args = Array.prototype.slice.call(arguments, 2);
                    var id = _nextId++;
                    var promise = (async function() {
                        if (delay > 0) {
                            await Deno.core.ops.op_sleep(delay);
                        } else {
                            await Promise.resolve();
                        }
                        if (_timers[id]) {
                            delete _timers[id];
                            callback.apply(null, args);
                        }
                    })();
                    _timers[id] = promise;
                    return id;
                };

                globalThis.clearTimeout = function(id) {
                    delete _timers[id];
                };

                globalThis.setInterval = function(callback, delay) {
                    var args = Array.prototype.slice.call(arguments, 2);
                    var id = _nextId++;
                    function schedule() {
                        _timers[id] = setTimeout(function() {
                            if (_timers[id] !== undefined) {
                                callback.apply(null, args);
                                schedule();
                            }
                        }, delay);
                    }
                    schedule();
                    return id;
                };

                globalThis.clearInterval = function(id) {
                    if (_timers[id] !== undefined) {
                        clearTimeout(_timers[id]);
                        delete _timers[id];
                    }
                };
            })();
            "#,
        );

        // Insert callback state into OpState if callbacks are enabled
        if has_callbacks {
            runtime.op_state().borrow_mut().put(CallbackState {
                request_tx: callback_tx,
                next_id: std::sync::atomic::AtomicU64::new(0),
            });

            // Set up the globalThis.Denox.callback() helper
            let _ = runtime.execute_script(
                "<denox_callback_init>",
                r#"
                globalThis.Denox = {
                    callback: function(name) {
                        var args = Array.prototype.slice.call(arguments, 1);
                        var result = Deno.core.ops.op_elixir_call(name, JSON.stringify(args));
                        return JSON.parse(result);
                    }
                };
                "#,
            );
        }

        // Enter the tokio runtime context so that async ops (e.g. op_sleep)
        // can access the reactor when spawned during execute_script.
        let _tokio_guard = tokio_rt.enter();

        while let Ok(cmd) = rx.recv() {
            match cmd {
                Command::Eval {
                    code,
                    transpile,
                    reply,
                } => {
                    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        process_eval(
                            &mut runtime, &tokio_rt, code, transpile, false, "<denox>",
                        )
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
                    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        process_eval(
                            &mut runtime, &tokio_rt, code, transpile, true, script_name,
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
                        process_eval_module(&mut runtime, &tokio_rt, path)
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
    // Use Env::send (works from dirty scheduler threads)
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
