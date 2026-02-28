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
}

struct RuntimeResource {
    sender: mpsc::Sender<Command>,
}

// SAFETY: The RuntimeResource only holds a channel sender, which is Send+Sync.
// The actual JsRuntime lives on a dedicated thread and is never shared.
unsafe impl Send for RuntimeResource {}
unsafe impl Sync for RuntimeResource {}

/// Transpile TypeScript to JavaScript using deno_ast (swc).
/// Strips type annotations without type-checking.
fn transpile_inline(ts_code: &str) -> Result<String, String> {
    use deno_ast::MediaType;
    use deno_ast::ParseParams;
    use deno_ast::SourceMapOption;
    use deno_ast::TranspileOptions;
    use deno_ast::TranspileModuleOptions;
    use deno_ast::EmitOptions;

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

/// Process a V8 eval on the runtime thread
fn process_eval(runtime: &mut JsRuntime, code: String, transpile: bool) -> Result<String, String> {
    let js_code = if transpile {
        transpile_inline(&code)?
    } else {
        code
    };

    let result = runtime
        .execute_script("<denox>", js_code)
        .map_err(|e| format!("{}", e))?;

    let scope = &mut runtime.handle_scope();
    let local = deno_core::v8::Local::new(scope, result);

    // Try serde_v8 first for structured data
    match deno_core::serde_v8::from_v8::<serde_json::Value>(scope, local) {
        Ok(json_val) => serde_json::to_string(&json_val)
            .map_err(|e| format!("JSON serialization error: {}", e)),
        Err(_) => {
            // Fallback to string conversion for non-JSON types (functions, symbols, undefined)
            Ok(local.to_rust_string_lossy(scope))
        }
    }
}

// Rustler wraps Result<T, E>:
//   Ok(value)  → {:ok, value}
//   Err(error) → {:error, error}

#[rustler::nif(schedule = "DirtyCpu")]
fn runtime_new() -> Result<ResourceArc<RuntimeResource>, String> {
    let (tx, rx) = mpsc::channel::<Command>();

    // Spawn a dedicated thread for this V8 isolate.
    // V8 isolates are single-threaded and require LIFO drop ordering on the same thread.
    // By dedicating a thread, we satisfy both constraints.
    std::thread::spawn(move || {
        let tokio_rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("Failed to create tokio runtime");

        let mut runtime = tokio_rt.block_on(async {
            JsRuntime::new(RuntimeOptions {
                ..Default::default()
            })
        });

        // Process commands until sender is dropped
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
            }
        }

        // JsRuntime is dropped here, on the same thread it was created
    });

    Ok(ResourceArc::new(RuntimeResource { sender: tx }))
}

fn send_eval(
    resource: &RuntimeResource,
    code: String,
    transpile: bool,
) -> Result<String, String> {
    let (reply_tx, reply_rx) = mpsc::channel();
    resource
        .sender
        .send(Command::Eval {
            code,
            transpile,
            reply: reply_tx,
        })
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
    send_eval(&resource, code, transpile)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn call_function(
    resource: ResourceArc<RuntimeResource>,
    func_name: String,
    args_json: String,
) -> Result<String, String> {
    let js_code = format!("((args) => {}(...args))({})", func_name, args_json);
    send_eval(&resource, js_code, false)
}

rustler::init!("Elixir.Denox.Native", load = on_load);

fn on_load(env: Env, _info: Term) -> bool {
    rustler::resource!(RuntimeResource, env);
    true
}
