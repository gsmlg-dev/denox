mod ts_loader;

use deno_core::JsRuntime;
use deno_core::RuntimeOptions;
use rustler::{Env, ResourceArc, Term};
use std::sync::mpsc;

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
}

// SAFETY: The RuntimeResource only holds a channel sender, which is Send+Sync.
// The actual JsRuntime lives on a dedicated thread and is never shared.
unsafe impl Send for RuntimeResource {}
unsafe impl Sync for RuntimeResource {}

/// Transpile TypeScript to JavaScript using deno_ast (swc).
fn transpile_inline(ts_code: &str) -> Result<String, String> {
    use deno_ast::{
        EmitOptions, MediaType, ParseParams, SourceMapOption, TranspileModuleOptions,
        TranspileOptions,
    };

    let specifier = deno_core::url::Url::parse("file:///denox_inline.ts")
        .map_err(|e| format!("URL parse error: {}", e))?;

    let parsed = deno_ast::parse_module(ParseParams {
        specifier,
        text: ts_code.into(),
        media_type: MediaType::TypeScript,
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

/// Extract a V8 value as a JSON string
fn extract_value(
    runtime: &mut JsRuntime,
    global: deno_core::v8::Global<deno_core::v8::Value>,
) -> Result<String, String> {
    let scope = &mut runtime.handle_scope();
    let local = deno_core::v8::Local::new(scope, global);

    match deno_core::serde_v8::from_v8::<serde_json::Value>(scope, local) {
        Ok(json_val) => {
            serde_json::to_string(&json_val).map_err(|e| format!("JSON serialization error: {}", e))
        }
        Err(_) => Ok(local.to_rust_string_lossy(scope)),
    }
}

/// Process a synchronous V8 eval on the runtime thread
fn process_eval(runtime: &mut JsRuntime, code: String, transpile: bool) -> Result<String, String> {
    let js_code = if transpile {
        transpile_inline(&code)?
    } else {
        code
    };

    let result = runtime
        .execute_script("<denox>", js_code)
        .map_err(|e| format!("{}", e))?;

    extract_value(runtime, result)
}

/// Process an async eval: wraps code in async IIFE, pumps event loop, inspects Promise
fn process_eval_async(
    runtime: &mut JsRuntime,
    tokio_rt: &tokio::runtime::Runtime,
    code: String,
    transpile: bool,
    script_name: &'static str,
) -> Result<String, String> {
    let js_code = if transpile {
        transpile_inline(&code)?
    } else {
        code
    };

    // Wrap in async IIFE so await/import() work
    let wrapped = format!("(async () => {{ {} }})()", js_code);

    let result = runtime
        .execute_script(script_name, wrapped)
        .map_err(|e| format!("{}", e))?;

    // Pump the event loop to settle the promise
    tokio_rt
        .block_on(runtime.run_event_loop(Default::default()))
        .map_err(|e| format!("Event loop error: {}", e))?;

    // Inspect the promise state
    {
        let scope = &mut runtime.handle_scope();
        let local = deno_core::v8::Local::new(scope, result);

        let promise = match deno_core::v8::Local::<deno_core::v8::Promise>::try_from(local) {
            Ok(p) => p,
            Err(_) => {
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

#[rustler::nif(schedule = "DirtyCpu")]
fn runtime_new(
    base_dir: String,
    cache_dir: String,
) -> Result<ResourceArc<RuntimeResource>, String> {
    let (tx, rx) = mpsc::channel::<Command>();

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
            JsRuntime::new(RuntimeOptions {
                module_loader: Some(std::rc::Rc::new(ts_loader::TsModuleLoader::new(
                    loader_cache_dir,
                ))),
                ..Default::default()
            })
        });

        while let Ok(cmd) = rx.recv() {
            match cmd {
                Command::Eval {
                    code,
                    transpile,
                    reply,
                } => {
                    let result = process_eval(&mut runtime, code, transpile);
                    let _ = reply.send(result);
                }
                Command::EvalAsync {
                    code,
                    transpile,
                    reply,
                } => {
                    let result =
                        process_eval_async(&mut runtime, &tokio_rt, code, transpile, script_name);
                    let _ = reply.send(result);
                }
                Command::EvalModule { path, reply } => {
                    let result = process_eval_module(&mut runtime, &tokio_rt, path);
                    let _ = reply.send(result);
                }
            }
        }
    });

    Ok(ResourceArc::new(RuntimeResource { sender: tx }))
}

fn send_command(
    resource: &RuntimeResource,
    cmd_fn: impl FnOnce(mpsc::Sender<Result<String, String>>) -> Command,
) -> Result<String, String> {
    let (reply_tx, reply_rx) = mpsc::channel();
    resource
        .sender
        .send(cmd_fn(reply_tx))
        .map_err(|_| "Runtime thread has shut down".to_string())?;

    reply_rx
        .recv()
        .map_err(|_| "Runtime thread died".to_string())?
}

#[rustler::nif(schedule = "DirtyCpu")]
fn eval(
    resource: ResourceArc<RuntimeResource>,
    code: String,
    transpile: bool,
) -> Result<String, String> {
    send_command(&resource, |reply| Command::Eval {
        code,
        transpile,
        reply,
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn eval_async(
    resource: ResourceArc<RuntimeResource>,
    code: String,
    transpile: bool,
) -> Result<String, String> {
    send_command(&resource, |reply| Command::EvalAsync {
        code,
        transpile,
        reply,
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn eval_module(resource: ResourceArc<RuntimeResource>, path: String) -> Result<String, String> {
    send_command(&resource, |reply| Command::EvalModule { path, reply })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn call_function(
    resource: ResourceArc<RuntimeResource>,
    func_name: String,
    args_json: String,
) -> Result<String, String> {
    let js_code = format!("((args) => {}(...args))({})", func_name, args_json);
    send_command(&resource, |reply| Command::Eval {
        code: js_code,
        transpile: false,
        reply,
    })
}

rustler::init!("Elixir.Denox.Native", load = on_load);

fn on_load(env: Env, _info: Term) -> bool {
    rustler::resource!(RuntimeResource, env);
    true
}
