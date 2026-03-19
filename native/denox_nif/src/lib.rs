mod callback_op;
mod fetch_op;
mod globals_op;
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

/// Process a V8 eval: execute code as a plain script, pump event loop,
/// resolve Promises.
///
/// Code runs as a plain script — simple expressions like `1 + 2` work
/// without `return`. For module-style evaluation with `import`/`export`,
/// use `process_eval_module_code` instead.
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
///
/// Unlike `process_eval` (which uses `execute_script`), this uses
/// `load_main_es_module_from_code` so that static `import`/`export` declarations
/// work. The caller must supply a unique specifier per invocation to avoid
/// module-cache collisions.
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

        let loader_cache_dir = if cache_dir.is_empty() {
            None
        } else {
            Some(cache_dir)
        };

        // Compute the base directory URL for module specifiers so that
        // relative imports (e.g. `./mod.ts`) resolve correctly.
        let base = if !base_dir.is_empty() {
            std::path::PathBuf::from(&base_dir)
                .canonicalize()
                .unwrap_or_else(|_| std::path::PathBuf::from(&base_dir))
        } else {
            std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("/"))
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
            opts.extensions.push(timer_op::denox_timer_ext::init_ops());

            // Register globals extension (performance.now, crypto.getRandomValues)
            opts.extensions
                .push(globals_op::denox_globals_ext::init_ops());

            // Register fetch extension for globalThis.fetch
            opts.extensions.push(fetch_op::denox_fetch_ext::init_ops());

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

        // Polyfill standard globals available in Node.js and Deno
        let _ = runtime.execute_script(
            "<denox_globals_polyfill>",
            r#"
            (function() {
                // ---- console ----
                if (typeof globalThis.console === "undefined") {
                    var _timers = {};
                    var _counts = {};
                    var noop = function() {};
                    globalThis.console = {
                        log: noop,
                        info: noop,
                        warn: noop,
                        error: noop,
                        debug: noop,
                        trace: noop,
                        dir: noop,
                        dirxml: noop,
                        table: noop,
                        clear: noop,
                        group: noop,
                        groupCollapsed: noop,
                        groupEnd: noop,
                        assert: noop,
                        count: function(label) {
                            label = label || "default";
                            _counts[label] = (_counts[label] || 0) + 1;
                        },
                        countReset: function(label) {
                            label = label || "default";
                            _counts[label] = 0;
                        },
                        time: function(label) {
                            label = label || "default";
                            _timers[label] = Date.now();
                        },
                        timeEnd: function(label) {
                            label = label || "default";
                            delete _timers[label];
                        },
                        timeLog: function() {}
                    };
                }

                // ---- atob / btoa ----
                if (typeof globalThis.atob === "undefined") {
                    var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
                    globalThis.btoa = function(input) {
                        var str = String(input);
                        var len = str.length;
                        var output = "";
                        for (var i = 0; i < len; i += 3) {
                            var a = str.charCodeAt(i);
                            var b = i + 1 < len ? str.charCodeAt(i + 1) : 0;
                            var c = i + 2 < len ? str.charCodeAt(i + 2) : 0;
                            var triple = (a << 16) | (b << 8) | c;
                            output += chars[(triple >> 18) & 63];
                            output += chars[(triple >> 12) & 63];
                            output += i + 1 < len ? chars[(triple >> 6) & 63] : "=";
                            output += i + 2 < len ? chars[triple & 63] : "=";
                        }
                        return output;
                    };
                    globalThis.atob = function(input) {
                        var str = String(input).replace(/[\s=]+$/g, "");
                        if (str.length === 0) return "";
                        var output = "";
                        var len = str.length;
                        for (var i = 0; i < len; i += 4) {
                            var a = chars.indexOf(str.charAt(i));
                            var b = i + 1 < len ? chars.indexOf(str.charAt(i + 1)) : 0;
                            var c = i + 2 < len ? chars.indexOf(str.charAt(i + 2)) : -1;
                            var d = i + 3 < len ? chars.indexOf(str.charAt(i + 3)) : -1;
                            var triple = (a << 18) | (b << 12) | ((c >= 0 ? c : 0) << 6) | (d >= 0 ? d : 0);
                            output += String.fromCharCode((triple >> 16) & 255);
                            if (c >= 0) output += String.fromCharCode((triple >> 8) & 255);
                            if (d >= 0) output += String.fromCharCode(triple & 255);
                        }
                        return output;
                    };
                }

                // ---- performance ----
                if (typeof globalThis.performance === "undefined") {
                    globalThis.performance = {
                        now: function() {
                            return Deno.core.ops.op_hrtime_now();
                        },
                        timeOrigin: Date.now()
                    };
                }

                // ---- navigator ----
                if (typeof globalThis.navigator === "undefined") {
                    globalThis.navigator = {
                        userAgent: "Denox",
                        language: "en",
                        languages: ["en"],
                        hardwareConcurrency: 1
                    };
                }

                // ---- structuredClone ----
                if (typeof globalThis.structuredClone === "undefined") {
                    globalThis.structuredClone = function(value) {
                        return JSON.parse(JSON.stringify(value));
                    };
                }

                // ---- queueMicrotask ----
                if (typeof globalThis.queueMicrotask === "undefined") {
                    globalThis.queueMicrotask = function(callback) {
                        Promise.resolve().then(callback);
                    };
                }

                // ---- crypto ----
                if (typeof globalThis.crypto === "undefined") {
                    globalThis.crypto = {};
                }
                if (typeof globalThis.crypto.getRandomValues === "undefined") {
                    globalThis.crypto.getRandomValues = function(typedArray) {
                        var buf = new Uint8Array(typedArray.buffer, typedArray.byteOffset, typedArray.byteLength);
                        Deno.core.ops.op_crypto_random(buf);
                        return typedArray;
                    };
                }
                if (typeof globalThis.crypto.randomUUID === "undefined") {
                    globalThis.crypto.randomUUID = function() {
                        var bytes = new Uint8Array(16);
                        crypto.getRandomValues(bytes);
                        bytes[6] = (bytes[6] & 0x0f) | 0x40;
                        bytes[8] = (bytes[8] & 0x3f) | 0x80;
                        var hex = Array.prototype.map.call(bytes, function(b) {
                            return ("0" + b.toString(16)).slice(-2);
                        }).join("");
                        return hex.slice(0,8) + "-" + hex.slice(8,12) + "-" + hex.slice(12,16) + "-" + hex.slice(16,20) + "-" + hex.slice(20);
                    };
                }

                // ---- EventTarget / Event ----
                if (typeof globalThis.Event === "undefined") {
                    globalThis.Event = function Event(type, opts) {
                        this.type = type;
                        this.bubbles = !!(opts && opts.bubbles);
                        this.cancelable = !!(opts && opts.cancelable);
                        this.defaultPrevented = false;
                        this.timeStamp = performance.now();
                    };
                    Event.prototype.preventDefault = function() { this.defaultPrevented = true; };
                    Event.prototype.stopPropagation = function() {};
                    Event.prototype.stopImmediatePropagation = function() {};
                }
                if (typeof globalThis.EventTarget === "undefined") {
                    globalThis.EventTarget = function EventTarget() {
                        this._listeners = {};
                    };
                    EventTarget.prototype.addEventListener = function(type, listener) {
                        if (!this._listeners[type]) this._listeners[type] = [];
                        this._listeners[type].push(listener);
                    };
                    EventTarget.prototype.removeEventListener = function(type, listener) {
                        var list = this._listeners[type];
                        if (list) {
                            this._listeners[type] = list.filter(function(l) { return l !== listener; });
                        }
                    };
                    EventTarget.prototype.dispatchEvent = function(event) {
                        var list = this._listeners[event.type];
                        if (list) {
                            list.forEach(function(l) { l.call(this, event); }.bind(this));
                        }
                        return !event.defaultPrevented;
                    };
                }

                // ---- AbortController / AbortSignal ----
                if (typeof globalThis.AbortController === "undefined") {
                    function AbortSignal() {
                        EventTarget.call(this);
                        this.aborted = false;
                        this.reason = undefined;
                    }
                    AbortSignal.prototype = Object.create(EventTarget.prototype);
                    AbortSignal.prototype.constructor = AbortSignal;
                    AbortSignal.prototype.throwIfAborted = function() {
                        if (this.aborted) throw this.reason;
                    };
                    AbortSignal.abort = function(reason) {
                        var signal = new AbortSignal();
                        signal.aborted = true;
                        signal.reason = reason !== undefined ? reason : new DOMException("The operation was aborted.", "AbortError");
                        return signal;
                    };
                    AbortSignal.timeout = function(ms) {
                        var signal = new AbortSignal();
                        setTimeout(function() {
                            signal.aborted = true;
                            signal.reason = new DOMException("The operation timed out.", "TimeoutError");
                            signal.dispatchEvent(new Event("abort"));
                        }, ms);
                        return signal;
                    };
                    globalThis.AbortSignal = AbortSignal;

                    globalThis.AbortController = function AbortController() {
                        this.signal = new AbortSignal();
                    };
                    AbortController.prototype.abort = function(reason) {
                        if (!this.signal.aborted) {
                            this.signal.aborted = true;
                            this.signal.reason = reason !== undefined ? reason : new DOMException("The operation was aborted.", "AbortError");
                            this.signal.dispatchEvent(new Event("abort"));
                        }
                    };
                }

                // ---- DOMException ----
                if (typeof globalThis.DOMException === "undefined") {
                    globalThis.DOMException = function DOMException(message, name) {
                        this.message = message || "";
                        this.name = name || "Error";
                    };
                    DOMException.prototype = Object.create(Error.prototype);
                    DOMException.prototype.constructor = DOMException;
                }

                // ---- TextEncoder / TextDecoder (UTF-8) ----
                if (typeof globalThis.TextEncoder === "undefined") {
                    globalThis.TextEncoder = function TextEncoder() {
                        this.encoding = "utf-8";
                    };
                    TextEncoder.prototype.encode = function(str) {
                        str = String(str);
                        var bytes = [];
                        for (var i = 0; i < str.length; i++) {
                            var code = str.charCodeAt(i);
                            if (code < 0x80) {
                                bytes.push(code);
                            } else if (code < 0x800) {
                                bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
                            } else if (code >= 0xd800 && code < 0xdc00 && i + 1 < str.length) {
                                var next = str.charCodeAt(i + 1);
                                if (next >= 0xdc00 && next < 0xe000) {
                                    var cp = ((code - 0xd800) << 10) + (next - 0xdc00) + 0x10000;
                                    bytes.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
                                    i++;
                                } else {
                                    bytes.push(0xef, 0xbf, 0xbd);
                                }
                            } else if (code >= 0xd800 && code < 0xe000) {
                                bytes.push(0xef, 0xbf, 0xbd);
                            } else {
                                bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
                            }
                        }
                        return new Uint8Array(bytes);
                    };
                    TextEncoder.prototype.encodeInto = function(str, dest) {
                        var encoded = this.encode(str);
                        var len = Math.min(encoded.length, dest.length);
                        dest.set(encoded.subarray(0, len));
                        return { read: str.length, written: len };
                    };
                }
                if (typeof globalThis.TextDecoder === "undefined") {
                    globalThis.TextDecoder = function TextDecoder(encoding) {
                        this.encoding = encoding || "utf-8";
                    };
                    TextDecoder.prototype.decode = function(input) {
                        if (!input || input.byteLength === 0) return "";
                        var bytes = new Uint8Array(input.buffer || input, input.byteOffset || 0, input.byteLength || input.length);
                        var result = "";
                        for (var i = 0; i < bytes.length; ) {
                            var b = bytes[i];
                            if (b < 0x80) {
                                result += String.fromCharCode(b);
                                i++;
                            } else if ((b & 0xe0) === 0xc0) {
                                result += String.fromCharCode(((b & 0x1f) << 6) | (bytes[i+1] & 0x3f));
                                i += 2;
                            } else if ((b & 0xf0) === 0xe0) {
                                result += String.fromCharCode(((b & 0x0f) << 12) | ((bytes[i+1] & 0x3f) << 6) | (bytes[i+2] & 0x3f));
                                i += 3;
                            } else if ((b & 0xf8) === 0xf0) {
                                var cp = ((b & 0x07) << 18) | ((bytes[i+1] & 0x3f) << 12) | ((bytes[i+2] & 0x3f) << 6) | (bytes[i+3] & 0x3f);
                                cp -= 0x10000;
                                result += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
                                i += 4;
                            } else {
                                result += "\ufffd";
                                i++;
                            }
                        }
                        return result;
                    };
                }

                // ---- URLSearchParams ----
                if (typeof globalThis.URLSearchParams === "undefined") {
                    globalThis.URLSearchParams = function URLSearchParams(init) {
                        this._entries = [];
                        if (typeof init === "string") {
                            var s = init.charAt(0) === "?" ? init.slice(1) : init;
                            if (s.length > 0) {
                                var pairs = s.split("&");
                                for (var i = 0; i < pairs.length; i++) {
                                    var idx = pairs[i].indexOf("=");
                                    var key = idx >= 0 ? pairs[i].slice(0, idx) : pairs[i];
                                    var val = idx >= 0 ? pairs[i].slice(idx + 1) : "";
                                    this._entries.push([decodeURIComponent(key.replace(/\+/g, " ")), decodeURIComponent(val.replace(/\+/g, " "))]);
                                }
                            }
                        } else if (init && typeof init === "object") {
                            if (Array.isArray(init)) {
                                for (var j = 0; j < init.length; j++) this._entries.push([String(init[j][0]), String(init[j][1])]);
                            } else {
                                var keys = Object.keys(init);
                                for (var k = 0; k < keys.length; k++) this._entries.push([keys[k], String(init[keys[k]])]);
                            }
                        }
                    };
                    var usp = URLSearchParams.prototype;
                    usp.get = function(name) {
                        for (var i = 0; i < this._entries.length; i++) {
                            if (this._entries[i][0] === name) return this._entries[i][1];
                        }
                        return null;
                    };
                    usp.getAll = function(name) {
                        return this._entries.filter(function(e) { return e[0] === name; }).map(function(e) { return e[1]; });
                    };
                    usp.has = function(name) { return this.get(name) !== null; };
                    usp.set = function(name, value) {
                        var found = false;
                        this._entries = this._entries.filter(function(e) {
                            if (e[0] === name) { if (!found) { e[1] = String(value); found = true; return true; } return false; }
                            return true;
                        });
                        if (!found) this._entries.push([name, String(value)]);
                    };
                    usp.append = function(name, value) { this._entries.push([String(name), String(value)]); };
                    usp.delete = function(name) { this._entries = this._entries.filter(function(e) { return e[0] !== name; }); };
                    usp.toString = function() {
                        return this._entries.map(function(e) { return encodeURIComponent(e[0]) + "=" + encodeURIComponent(e[1]); }).join("&");
                    };
                    usp.forEach = function(cb, thisArg) {
                        for (var i = 0; i < this._entries.length; i++) cb.call(thisArg, this._entries[i][1], this._entries[i][0], this);
                    };
                    usp.keys = function() { return this._entries.map(function(e) { return e[0]; })[Symbol.iterator](); };
                    usp.values = function() { return this._entries.map(function(e) { return e[1]; })[Symbol.iterator](); };
                    usp.entries = function() { return this._entries[Symbol.iterator](); };
                    usp[Symbol.iterator] = function() { return this.entries(); };
                }

                // ---- URL ----
                if (typeof globalThis.URL === "undefined") {
                    globalThis.URL = function URL(url, base) {
                        var href = base ? new URL(base).href : "";
                        if (base) {
                            // Resolve relative URL against base
                            if (url.match(/^[a-zA-Z][a-zA-Z0-9+\-.]*:/)) {
                                href = url;
                            } else if (url.charAt(0) === "/") {
                                var m = href.match(/^([a-zA-Z][a-zA-Z0-9+\-.]*:\/\/[^/?#]*)/);
                                href = m ? m[1] + url : url;
                            } else {
                                href = href.replace(/[?#].*$/, "").replace(/\/[^/]*$/, "/") + url;
                            }
                        } else {
                            href = url;
                        }
                        // Parse the URL
                        var match = href.match(/^([a-zA-Z][a-zA-Z0-9+\-.]*):\/\/(?:([^:@]*)(?::([^@]*))?@)?([^:/?#]*)(?::(\d+))?(\/[^?#]*)?(\?[^#]*)?(#.*)?$/);
                        if (!match) throw new TypeError("Invalid URL: " + url);
                        this.protocol = match[1] + ":";
                        this.username = match[2] || "";
                        this.password = match[3] || "";
                        this.hostname = match[4] || "";
                        this.port = match[5] || "";
                        this.pathname = match[6] || "/";
                        this.search = match[7] || "";
                        this.hash = match[8] || "";
                        this.host = this.hostname + (this.port ? ":" + this.port : "");
                        this.origin = this.protocol + "//" + this.host;
                        this.href = this.origin + this.pathname + this.search + this.hash;
                        this.searchParams = new URLSearchParams(this.search);
                    };
                    URL.prototype.toString = function() { return this.href; };
                    URL.prototype.toJSON = function() { return this.href; };
                }
            })();
            "#,
        );

        // Polyfill globalThis.fetch, Headers, Request, Response
        // Uses the native op_fetch async op backed by ureq.
        let _ = runtime.execute_script(
            "<denox_fetch_polyfill>",
            r#"
            (function() {
                // ---- Headers ----
                function Headers(init) {
                    this._headers = {};
                    if (init) {
                        if (init instanceof Headers) {
                            var entries = init.entries();
                            for (var i = 0; i < entries.length; i++) {
                                this.append(entries[i][0], entries[i][1]);
                            }
                        } else if (Array.isArray(init)) {
                            for (var i = 0; i < init.length; i++) {
                                this.append(init[i][0], init[i][1]);
                            }
                        } else {
                            var keys = Object.keys(init);
                            for (var i = 0; i < keys.length; i++) {
                                this.append(keys[i], init[keys[i]]);
                            }
                        }
                    }
                }
                Headers.prototype.append = function(name, value) {
                    var key = name.toLowerCase();
                    if (this._headers[key]) {
                        this._headers[key] = this._headers[key] + ", " + value;
                    } else {
                        this._headers[key] = String(value);
                    }
                };
                Headers.prototype.set = function(name, value) {
                    this._headers[name.toLowerCase()] = String(value);
                };
                Headers.prototype.get = function(name) {
                    var v = this._headers[name.toLowerCase()];
                    return v !== undefined ? v : null;
                };
                Headers.prototype.has = function(name) {
                    return name.toLowerCase() in this._headers;
                };
                Headers.prototype.delete = function(name) {
                    delete this._headers[name.toLowerCase()];
                };
                Headers.prototype.entries = function() {
                    var result = [];
                    var keys = Object.keys(this._headers);
                    for (var i = 0; i < keys.length; i++) {
                        result.push([keys[i], this._headers[keys[i]]]);
                    }
                    return result;
                };
                Headers.prototype.keys = function() {
                    return Object.keys(this._headers);
                };
                Headers.prototype.values = function() {
                    var vals = [];
                    var keys = Object.keys(this._headers);
                    for (var i = 0; i < keys.length; i++) {
                        vals.push(this._headers[keys[i]]);
                    }
                    return vals;
                };
                Headers.prototype.forEach = function(callback, thisArg) {
                    var keys = Object.keys(this._headers);
                    for (var i = 0; i < keys.length; i++) {
                        callback.call(thisArg, this._headers[keys[i]], keys[i], this);
                    }
                };
                globalThis.Headers = Headers;

                // ---- Response ----
                function Response(body, init) {
                    this._body = body || null;
                    this._bodyUsed = false;
                    init = init || {};
                    this.status = init.status !== undefined ? init.status : 200;
                    this.statusText = init.statusText || "";
                    this.ok = this.status >= 200 && this.status < 300;
                    this.headers = init.headers instanceof Headers ? init.headers : new Headers(init.headers || {});
                    this.type = "basic";
                    this.url = init.url || "";
                    this.redirected = false;
                    this.body = null;
                    this.bodyUsed = false;
                }
                Response.prototype._consumeBody = function() {
                    if (this._bodyUsed) {
                        throw new TypeError("Body has already been consumed");
                    }
                    this._bodyUsed = true;
                    this.bodyUsed = true;
                };
                Response.prototype.text = function() {
                    this._consumeBody();
                    var body = this._body;
                    if (body === null) return Promise.resolve("");
                    if (typeof body === "string") return Promise.resolve(body);
                    // body is Uint8Array from native op
                    var decoder = new TextDecoder();
                    return Promise.resolve(decoder.decode(body));
                };
                Response.prototype.json = function() {
                    return this.text().then(function(t) { return JSON.parse(t); });
                };
                Response.prototype.arrayBuffer = function() {
                    this._consumeBody();
                    var body = this._body;
                    if (body === null) return Promise.resolve(new ArrayBuffer(0));
                    if (body instanceof ArrayBuffer) return Promise.resolve(body);
                    if (body instanceof Uint8Array) return Promise.resolve(body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength));
                    // string
                    var encoder = new TextEncoder();
                    var encoded = encoder.encode(body);
                    return Promise.resolve(encoded.buffer);
                };
                Response.prototype.clone = function() {
                    return new Response(this._body, {
                        status: this.status,
                        statusText: this.statusText,
                        headers: new Headers(this.headers.entries()),
                        url: this.url
                    });
                };
                globalThis.Response = Response;

                // ---- Request ----
                function Request(input, init) {
                    init = init || {};
                    if (typeof input === "string") {
                        this.url = input;
                    } else if (input instanceof Request) {
                        this.url = input.url;
                        init.method = init.method || input.method;
                        init.headers = init.headers || input.headers;
                        init.body = init.body !== undefined ? init.body : input._body;
                    } else {
                        this.url = String(input);
                    }
                    this.method = (init.method || "GET").toUpperCase();
                    this.headers = init.headers instanceof Headers ? init.headers : new Headers(init.headers || {});
                    this._body = init.body !== undefined ? init.body : null;
                    this.body = null;
                    this.bodyUsed = false;
                }
                globalThis.Request = Request;

                // ---- fetch ----
                globalThis.fetch = async function fetch(input, init) {
                    init = init || {};
                    var url, method, headers, body;

                    if (input instanceof Request) {
                        url = input.url;
                        method = init.method || input.method;
                        headers = init.headers ? (init.headers instanceof Headers ? init.headers : new Headers(init.headers)) : input.headers;
                        body = init.body !== undefined ? init.body : input._body;
                    } else {
                        url = String(input);
                        method = (init.method || "GET").toUpperCase();
                        headers = init.headers instanceof Headers ? init.headers : new Headers(init.headers || {});
                        body = init.body !== undefined ? init.body : null;
                    }

                    // Convert headers to array of [name, value] pairs for the native op
                    var headerPairs = headers.entries();

                    // Convert body to Uint8Array if it's a string
                    var bodyBytes = null;
                    if (body !== null && body !== undefined) {
                        if (typeof body === "string") {
                            var encoder = new TextEncoder();
                            bodyBytes = encoder.encode(body);
                            if (!headers.has("content-type")) {
                                headers.set("content-type", "text/plain;charset=UTF-8");
                            }
                        } else if (body instanceof Uint8Array) {
                            bodyBytes = body;
                        } else if (body instanceof ArrayBuffer) {
                            bodyBytes = new Uint8Array(body);
                        }
                    }

                    var result = await Deno.core.ops.op_fetch(url, method, headerPairs, bodyBytes);

                    var responseHeaders = new Headers(result.headers);
                    // result.body is an array of numbers from serde, convert to Uint8Array
                    var responseBody = new Uint8Array(result.body);

                    return new Response(responseBody, {
                        status: result.status,
                        statusText: result.status_text,
                        headers: responseHeaders,
                        url: url
                    });
                };
            })();
            "#,
        );

        // Polyfill remaining web/Node.js globals for compatibility
        let _ = runtime.execute_script(
            "<denox_extended_globals>",
            r#"
            (function() {
                // ---- Simple aliases and properties ----
                if (typeof globalThis.global === "undefined") globalThis.global = globalThis;
                if (typeof globalThis.self === "undefined") globalThis.self = globalThis;
                if (typeof globalThis.name === "undefined") globalThis.name = "";
                if (typeof globalThis.closed === "undefined") globalThis.closed = false;

                // Event handler properties (null by default)
                var eventHandlers = ["onbeforeunload", "onerror", "onload", "onunhandledrejection", "onunload"];
                for (var i = 0; i < eventHandlers.length; i++) {
                    if (typeof globalThis[eventHandlers[i]] === "undefined") {
                        globalThis[eventHandlers[i]] = null;
                    }
                }

                // ---- alert / confirm / prompt / close ----
                if (typeof globalThis.alert === "undefined") {
                    globalThis.alert = function(message) { /* no-op in embedded runtime */ };
                }
                if (typeof globalThis.confirm === "undefined") {
                    globalThis.confirm = function(message) { return false; };
                }
                if (typeof globalThis.prompt === "undefined") {
                    globalThis.prompt = function(message, defaultValue) { return defaultValue !== undefined ? String(defaultValue) : null; };
                }
                if (typeof globalThis.close === "undefined") {
                    globalThis.close = function() { /* no-op */ };
                }

                // ---- reportError ----
                if (typeof globalThis.reportError === "undefined") {
                    globalThis.reportError = function(error) {
                        if (typeof globalThis.onerror === "function") {
                            globalThis.onerror(error);
                        } else {
                            console.error("Uncaught", error);
                        }
                    };
                }

                // ---- setImmediate / clearImmediate ----
                if (typeof globalThis.setImmediate === "undefined") {
                    globalThis.setImmediate = function(callback) {
                        var args = Array.prototype.slice.call(arguments, 1);
                        return setTimeout(function() { callback.apply(null, args); }, 0);
                    };
                }
                if (typeof globalThis.clearImmediate === "undefined") {
                    globalThis.clearImmediate = function(id) { clearTimeout(id); };
                }

                // ---- CustomEvent ----
                if (typeof globalThis.CustomEvent === "undefined") {
                    function CustomEvent(type, eventInitDict) {
                        Event.call(this, type, eventInitDict);
                        this.detail = (eventInitDict && eventInitDict.detail !== undefined) ? eventInitDict.detail : null;
                    }
                    CustomEvent.prototype = Object.create(Event.prototype);
                    CustomEvent.prototype.constructor = CustomEvent;
                    globalThis.CustomEvent = CustomEvent;
                }

                // ---- ErrorEvent ----
                if (typeof globalThis.ErrorEvent === "undefined") {
                    function ErrorEvent(type, eventInitDict) {
                        Event.call(this, type, eventInitDict);
                        eventInitDict = eventInitDict || {};
                        this.message = eventInitDict.message || "";
                        this.filename = eventInitDict.filename || "";
                        this.lineno = eventInitDict.lineno || 0;
                        this.colno = eventInitDict.colno || 0;
                        this.error = eventInitDict.error || null;
                    }
                    ErrorEvent.prototype = Object.create(Event.prototype);
                    ErrorEvent.prototype.constructor = ErrorEvent;
                    globalThis.ErrorEvent = ErrorEvent;
                }

                // ---- CloseEvent ----
                if (typeof globalThis.CloseEvent === "undefined") {
                    function CloseEvent(type, eventInitDict) {
                        Event.call(this, type, eventInitDict);
                        eventInitDict = eventInitDict || {};
                        this.wasClean = eventInitDict.wasClean || false;
                        this.code = eventInitDict.code || 0;
                        this.reason = eventInitDict.reason || "";
                    }
                    CloseEvent.prototype = Object.create(Event.prototype);
                    CloseEvent.prototype.constructor = CloseEvent;
                    globalThis.CloseEvent = CloseEvent;
                }

                // ---- MessageEvent ----
                if (typeof globalThis.MessageEvent === "undefined") {
                    function MessageEvent(type, eventInitDict) {
                        Event.call(this, type, eventInitDict);
                        eventInitDict = eventInitDict || {};
                        this.data = eventInitDict.data !== undefined ? eventInitDict.data : null;
                        this.origin = eventInitDict.origin || "";
                        this.lastEventId = eventInitDict.lastEventId || "";
                        this.source = eventInitDict.source || null;
                        this.ports = eventInitDict.ports || [];
                    }
                    MessageEvent.prototype = Object.create(Event.prototype);
                    MessageEvent.prototype.constructor = MessageEvent;
                    globalThis.MessageEvent = MessageEvent;
                }

                // ---- ProgressEvent ----
                if (typeof globalThis.ProgressEvent === "undefined") {
                    function ProgressEvent(type, eventInitDict) {
                        Event.call(this, type, eventInitDict);
                        eventInitDict = eventInitDict || {};
                        this.lengthComputable = eventInitDict.lengthComputable || false;
                        this.loaded = eventInitDict.loaded || 0;
                        this.total = eventInitDict.total || 0;
                    }
                    ProgressEvent.prototype = Object.create(Event.prototype);
                    ProgressEvent.prototype.constructor = ProgressEvent;
                    globalThis.ProgressEvent = ProgressEvent;
                }

                // ---- PromiseRejectionEvent ----
                if (typeof globalThis.PromiseRejectionEvent === "undefined") {
                    function PromiseRejectionEvent(type, eventInitDict) {
                        Event.call(this, type, eventInitDict);
                        eventInitDict = eventInitDict || {};
                        this.promise = eventInitDict.promise || null;
                        this.reason = eventInitDict.reason || undefined;
                    }
                    PromiseRejectionEvent.prototype = Object.create(Event.prototype);
                    PromiseRejectionEvent.prototype.constructor = PromiseRejectionEvent;
                    globalThis.PromiseRejectionEvent = PromiseRejectionEvent;
                }

                // ---- Navigator constructor ----
                if (typeof globalThis.Navigator === "undefined") {
                    function Navigator() {}
                    Navigator.prototype = Object.getPrototypeOf(globalThis.navigator || {});
                    globalThis.Navigator = Navigator;
                }

                // ---- Performance and related classes ----
                if (typeof globalThis.Performance === "undefined") {
                    function Performance() {}
                    if (globalThis.performance) {
                        Performance.prototype = Object.getPrototypeOf(globalThis.performance);
                    }
                    globalThis.Performance = Performance;
                }

                if (typeof globalThis.PerformanceEntry === "undefined") {
                    function PerformanceEntry(name, entryType, startTime, duration) {
                        this.name = name || "";
                        this.entryType = entryType || "";
                        this.startTime = startTime || 0;
                        this.duration = duration || 0;
                    }
                    PerformanceEntry.prototype.toJSON = function() {
                        return { name: this.name, entryType: this.entryType, startTime: this.startTime, duration: this.duration };
                    };
                    globalThis.PerformanceEntry = PerformanceEntry;
                }

                if (typeof globalThis.PerformanceMark === "undefined") {
                    function PerformanceMark(name, options) {
                        PerformanceEntry.call(this, name, "mark", (options && options.startTime) || performance.now(), 0);
                        this.detail = (options && options.detail) || null;
                    }
                    PerformanceMark.prototype = Object.create(PerformanceEntry.prototype);
                    PerformanceMark.prototype.constructor = PerformanceMark;
                    globalThis.PerformanceMark = PerformanceMark;
                }

                if (typeof globalThis.PerformanceMeasure === "undefined") {
                    function PerformanceMeasure(name, startTime, duration) {
                        PerformanceEntry.call(this, name, "measure", startTime, duration);
                        this.detail = null;
                    }
                    PerformanceMeasure.prototype = Object.create(PerformanceEntry.prototype);
                    PerformanceMeasure.prototype.constructor = PerformanceMeasure;
                    globalThis.PerformanceMeasure = PerformanceMeasure;
                }

                if (typeof globalThis.PerformanceObserverEntryList === "undefined") {
                    function PerformanceObserverEntryList(entries) {
                        this._entries = entries || [];
                    }
                    PerformanceObserverEntryList.prototype.getEntries = function() { return this._entries.slice(); };
                    PerformanceObserverEntryList.prototype.getEntriesByType = function(type) {
                        return this._entries.filter(function(e) { return e.entryType === type; });
                    };
                    PerformanceObserverEntryList.prototype.getEntriesByName = function(name, type) {
                        return this._entries.filter(function(e) {
                            return e.name === name && (!type || e.entryType === type);
                        });
                    };
                    globalThis.PerformanceObserverEntryList = PerformanceObserverEntryList;
                }

                if (typeof globalThis.PerformanceObserver === "undefined") {
                    function PerformanceObserver(callback) {
                        this._callback = callback;
                        this._entryTypes = [];
                    }
                    PerformanceObserver.prototype.observe = function(options) {
                        this._entryTypes = (options && options.entryTypes) || [];
                    };
                    PerformanceObserver.prototype.disconnect = function() { this._entryTypes = []; };
                    PerformanceObserver.prototype.takeRecords = function() { return []; };
                    PerformanceObserver.supportedEntryTypes = ["mark", "measure"];
                    globalThis.PerformanceObserver = PerformanceObserver;
                }

                // ---- Crypto / SubtleCrypto / CryptoKey constructors ----
                if (typeof globalThis.Crypto === "undefined") {
                    function Crypto() {}
                    if (globalThis.crypto) {
                        Crypto.prototype = Object.getPrototypeOf(globalThis.crypto);
                    }
                    globalThis.Crypto = Crypto;
                }

                if (typeof globalThis.SubtleCrypto === "undefined") {
                    function SubtleCrypto() {}
                    var notSupported = function() { return Promise.reject(new DOMException("SubtleCrypto not available", "NotSupportedError")); };
                    SubtleCrypto.prototype.encrypt = notSupported;
                    SubtleCrypto.prototype.decrypt = notSupported;
                    SubtleCrypto.prototype.sign = notSupported;
                    SubtleCrypto.prototype.verify = notSupported;
                    SubtleCrypto.prototype.digest = notSupported;
                    SubtleCrypto.prototype.generateKey = notSupported;
                    SubtleCrypto.prototype.importKey = notSupported;
                    SubtleCrypto.prototype.exportKey = notSupported;
                    SubtleCrypto.prototype.deriveBits = notSupported;
                    SubtleCrypto.prototype.deriveKey = notSupported;
                    SubtleCrypto.prototype.wrapKey = notSupported;
                    SubtleCrypto.prototype.unwrapKey = notSupported;
                    globalThis.SubtleCrypto = SubtleCrypto;
                }

                if (typeof globalThis.CryptoKey === "undefined") {
                    function CryptoKey() {
                        this.type = "";
                        this.extractable = false;
                        this.algorithm = {};
                        this.usages = [];
                    }
                    globalThis.CryptoKey = CryptoKey;
                }

                // ---- Window ----
                if (typeof globalThis.Window === "undefined") {
                    globalThis.Window = function Window() { throw new TypeError("Illegal constructor"); };
                    globalThis.Window.prototype = globalThis;
                }

                // ---- Blob ----
                if (typeof globalThis.Blob === "undefined") {
                    function Blob(blobParts, options) {
                        options = options || {};
                        this.type = options.type ? String(options.type).toLowerCase() : "";
                        var parts = blobParts || [];
                        var buffers = [];
                        for (var i = 0; i < parts.length; i++) {
                            var part = parts[i];
                            if (part instanceof Blob) {
                                buffers.push(part._buffer);
                            } else if (part instanceof ArrayBuffer) {
                                buffers.push(new Uint8Array(part));
                            } else if (ArrayBuffer.isView(part)) {
                                buffers.push(new Uint8Array(part.buffer, part.byteOffset, part.byteLength));
                            } else {
                                var encoder = new TextEncoder();
                                buffers.push(encoder.encode(String(part)));
                            }
                        }
                        var totalLength = 0;
                        for (var j = 0; j < buffers.length; j++) totalLength += buffers[j].byteLength;
                        var combined = new Uint8Array(totalLength);
                        var offset = 0;
                        for (var k = 0; k < buffers.length; k++) {
                            combined.set(buffers[k], offset);
                            offset += buffers[k].byteLength;
                        }
                        this._buffer = combined;
                        this.size = totalLength;
                    }
                    Blob.prototype.slice = function(start, end, contentType) {
                        start = start || 0;
                        end = end !== undefined ? end : this.size;
                        if (start < 0) start = Math.max(this.size + start, 0);
                        if (end < 0) end = Math.max(this.size + end, 0);
                        var sliced = this._buffer.slice(start, end);
                        var blob = new Blob([], { type: contentType || this.type });
                        blob._buffer = sliced;
                        blob.size = sliced.byteLength;
                        return blob;
                    };
                    Blob.prototype.text = function() {
                        var decoder = new TextDecoder();
                        return Promise.resolve(decoder.decode(this._buffer));
                    };
                    Blob.prototype.arrayBuffer = function() {
                        return Promise.resolve(this._buffer.buffer.slice(this._buffer.byteOffset, this._buffer.byteOffset + this._buffer.byteLength));
                    };
                    Blob.prototype.stream = function() {
                        throw new Error("Blob.stream() not supported");
                    };
                    globalThis.Blob = Blob;
                }

                // ---- File ----
                if (typeof globalThis.File === "undefined") {
                    function File(fileBits, fileName, options) {
                        Blob.call(this, fileBits, options);
                        this.name = fileName;
                        this.lastModified = (options && options.lastModified) || Date.now();
                    }
                    File.prototype = Object.create(Blob.prototype);
                    File.prototype.constructor = File;
                    globalThis.File = File;
                }

                // ---- FileReader ----
                if (typeof globalThis.FileReader === "undefined") {
                    function FileReader() {
                        this.result = null;
                        this.error = null;
                        this.readyState = 0; // EMPTY
                        this.onload = null;
                        this.onerror = null;
                        this.onloadend = null;
                        this.onloadstart = null;
                        this.onprogress = null;
                        this.onabort = null;
                    }
                    FileReader.EMPTY = 0;
                    FileReader.LOADING = 1;
                    FileReader.DONE = 2;
                    FileReader.prototype.readAsArrayBuffer = function(blob) {
                        var self = this;
                        self.readyState = 1;
                        blob.arrayBuffer().then(function(buf) {
                            self.result = buf;
                            self.readyState = 2;
                            if (self.onload) self.onload({ target: self });
                            if (self.onloadend) self.onloadend({ target: self });
                        });
                    };
                    FileReader.prototype.readAsText = function(blob, encoding) {
                        var self = this;
                        self.readyState = 1;
                        blob.text().then(function(text) {
                            self.result = text;
                            self.readyState = 2;
                            if (self.onload) self.onload({ target: self });
                            if (self.onloadend) self.onloadend({ target: self });
                        });
                    };
                    FileReader.prototype.readAsDataURL = function(blob) {
                        var self = this;
                        self.readyState = 1;
                        blob.arrayBuffer().then(function(buf) {
                            var bytes = new Uint8Array(buf);
                            var binary = "";
                            for (var i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
                            self.result = "data:" + (blob.type || "application/octet-stream") + ";base64," + btoa(binary);
                            self.readyState = 2;
                            if (self.onload) self.onload({ target: self });
                            if (self.onloadend) self.onloadend({ target: self });
                        });
                    };
                    FileReader.prototype.abort = function() {
                        this.readyState = 2;
                        if (this.onabort) this.onabort({ target: this });
                    };
                    globalThis.FileReader = FileReader;
                }

                // ---- FormData ----
                if (typeof globalThis.FormData === "undefined") {
                    function FormData() {
                        this._entries = [];
                    }
                    FormData.prototype.append = function(name, value, filename) {
                        this._entries.push([String(name), value, filename]);
                    };
                    FormData.prototype.delete = function(name) {
                        this._entries = this._entries.filter(function(e) { return e[0] !== name; });
                    };
                    FormData.prototype.get = function(name) {
                        for (var i = 0; i < this._entries.length; i++) {
                            if (this._entries[i][0] === name) return this._entries[i][1];
                        }
                        return null;
                    };
                    FormData.prototype.getAll = function(name) {
                        return this._entries.filter(function(e) { return e[0] === name; }).map(function(e) { return e[1]; });
                    };
                    FormData.prototype.has = function(name) {
                        return this._entries.some(function(e) { return e[0] === name; });
                    };
                    FormData.prototype.set = function(name, value, filename) {
                        this.delete(name);
                        this.append(name, value, filename);
                    };
                    FormData.prototype.entries = function() { return this._entries.map(function(e) { return [e[0], e[1]]; }); };
                    FormData.prototype.keys = function() { return this._entries.map(function(e) { return e[0]; }); };
                    FormData.prototype.values = function() { return this._entries.map(function(e) { return e[1]; }); };
                    FormData.prototype.forEach = function(callback, thisArg) {
                        for (var i = 0; i < this._entries.length; i++) {
                            callback.call(thisArg, this._entries[i][1], this._entries[i][0], this);
                        }
                    };
                    globalThis.FormData = FormData;
                }

                // ---- Storage (in-memory) ----
                if (typeof globalThis.Storage === "undefined") {
                    function Storage() {
                        this._data = {};
                        this.length = 0;
                    }
                    Storage.prototype.getItem = function(key) {
                        return this._data.hasOwnProperty(key) ? this._data[key] : null;
                    };
                    Storage.prototype.setItem = function(key, value) {
                        if (!this._data.hasOwnProperty(key)) this.length++;
                        this._data[key] = String(value);
                    };
                    Storage.prototype.removeItem = function(key) {
                        if (this._data.hasOwnProperty(key)) {
                            delete this._data[key];
                            this.length--;
                        }
                    };
                    Storage.prototype.clear = function() {
                        this._data = {};
                        this.length = 0;
                    };
                    Storage.prototype.key = function(index) {
                        var keys = Object.keys(this._data);
                        return index < keys.length ? keys[index] : null;
                    };
                    globalThis.Storage = Storage;
                }
                if (typeof globalThis.localStorage === "undefined") {
                    globalThis.localStorage = new Storage();
                }
                if (typeof globalThis.sessionStorage === "undefined") {
                    globalThis.sessionStorage = new Storage();
                }

                // ---- Location ----
                if (typeof globalThis.Location === "undefined") {
                    function Location() {
                        this.href = "about:blank";
                        this.origin = "null";
                        this.protocol = "about:";
                        this.host = "";
                        this.hostname = "";
                        this.port = "";
                        this.pathname = "blank";
                        this.search = "";
                        this.hash = "";
                    }
                    Location.prototype.assign = function(url) { this.href = url; };
                    Location.prototype.replace = function(url) { this.href = url; };
                    Location.prototype.reload = function() {};
                    Location.prototype.toString = function() { return this.href; };
                    globalThis.Location = Location;
                }
                if (typeof globalThis.location === "undefined") {
                    globalThis.location = new Location();
                }

                // ---- Buffer (Node.js compat) ----
                if (typeof globalThis.Buffer === "undefined") {
                    function Buffer(arg, encodingOrOffset, length) {
                        if (typeof arg === "number") {
                            return new Uint8Array(arg);
                        }
                        if (typeof arg === "string") {
                            var encoder = new TextEncoder();
                            return encoder.encode(arg);
                        }
                        if (arg instanceof ArrayBuffer) {
                            return new Uint8Array(arg, encodingOrOffset || 0, length);
                        }
                        if (ArrayBuffer.isView(arg) || Array.isArray(arg)) {
                            return new Uint8Array(arg);
                        }
                        return new Uint8Array(0);
                    }
                    Buffer.from = function(value, encoding) {
                        if (typeof value === "string") {
                            if (encoding === "base64") {
                                var binary = atob(value);
                                var bytes = new Uint8Array(binary.length);
                                for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
                                return bytes;
                            }
                            return new TextEncoder().encode(value);
                        }
                        if (Array.isArray(value)) return new Uint8Array(value);
                        if (value instanceof ArrayBuffer) return new Uint8Array(value);
                        if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
                        return new Uint8Array(0);
                    };
                    Buffer.alloc = function(size, fill) {
                        var buf = new Uint8Array(size);
                        if (fill !== undefined) buf.fill(typeof fill === "number" ? fill : 0);
                        return buf;
                    };
                    Buffer.allocUnsafe = function(size) { return new Uint8Array(size); };
                    Buffer.isBuffer = function(obj) { return obj instanceof Uint8Array; };
                    Buffer.concat = function(list, totalLength) {
                        if (!totalLength) {
                            totalLength = 0;
                            for (var i = 0; i < list.length; i++) totalLength += list[i].length;
                        }
                        var result = new Uint8Array(totalLength);
                        var offset = 0;
                        for (var j = 0; j < list.length; j++) {
                            result.set(list[j], offset);
                            offset += list[j].length;
                        }
                        return result;
                    };
                    Buffer.byteLength = function(string, encoding) {
                        return new TextEncoder().encode(string).length;
                    };
                    globalThis.Buffer = Buffer;
                }

                // ---- process (minimal Node.js compat) ----
                if (typeof globalThis.process === "undefined") {
                    globalThis.process = {
                        env: {},
                        argv: [],
                        version: "v0.0.0",
                        versions: {},
                        platform: "denox",
                        arch: "unknown",
                        pid: 0,
                        cwd: function() { return "/"; },
                        exit: function(code) { throw new Error("process.exit(" + (code || 0) + ") called"); },
                        nextTick: function(callback) {
                            var args = Array.prototype.slice.call(arguments, 1);
                            queueMicrotask(function() { callback.apply(null, args); });
                        },
                        stdout: { write: function(s) { /* no-op */ } },
                        stderr: { write: function(s) { /* no-op */ } },
                        hrtime: {
                            bigint: function() { return BigInt(Math.round(performance.now() * 1e6)); }
                        }
                    };
                }

                // ---- Streams API ----
                if (typeof globalThis.ReadableStream === "undefined") {
                    function ReadableStream(underlyingSource, strategy) {
                        this._underlyingSource = underlyingSource || {};
                        this._strategy = strategy || {};
                        this.locked = false;
                    }
                    ReadableStream.prototype.getReader = function(options) {
                        this.locked = true;
                        return new ReadableStreamDefaultReader(this);
                    };
                    ReadableStream.prototype.cancel = function(reason) { return Promise.resolve(); };
                    ReadableStream.prototype.pipeThrough = function(transform, options) { return transform.readable; };
                    ReadableStream.prototype.pipeTo = function(dest, options) { return Promise.resolve(); };
                    ReadableStream.prototype.tee = function() { return [new ReadableStream(), new ReadableStream()]; };
                    globalThis.ReadableStream = ReadableStream;
                }

                if (typeof globalThis.ReadableStreamDefaultReader === "undefined") {
                    function ReadableStreamDefaultReader(stream) {
                        this._stream = stream;
                        this.closed = Promise.resolve();
                    }
                    ReadableStreamDefaultReader.prototype.read = function() {
                        return Promise.resolve({ value: undefined, done: true });
                    };
                    ReadableStreamDefaultReader.prototype.cancel = function(reason) { return Promise.resolve(); };
                    ReadableStreamDefaultReader.prototype.releaseLock = function() {
                        if (this._stream) this._stream.locked = false;
                    };
                    globalThis.ReadableStreamDefaultReader = ReadableStreamDefaultReader;
                }

                if (typeof globalThis.ReadableStreamBYOBReader === "undefined") {
                    function ReadableStreamBYOBReader(stream) {
                        this._stream = stream;
                        this.closed = Promise.resolve();
                    }
                    ReadableStreamBYOBReader.prototype.read = function(view) {
                        return Promise.resolve({ value: view, done: true });
                    };
                    ReadableStreamBYOBReader.prototype.cancel = function(reason) { return Promise.resolve(); };
                    ReadableStreamBYOBReader.prototype.releaseLock = function() {};
                    globalThis.ReadableStreamBYOBReader = ReadableStreamBYOBReader;
                }

                if (typeof globalThis.ReadableStreamBYOBRequest === "undefined") {
                    function ReadableStreamBYOBRequest() { this.view = null; }
                    ReadableStreamBYOBRequest.prototype.respond = function(bytesWritten) {};
                    ReadableStreamBYOBRequest.prototype.respondWithNewView = function(view) {};
                    globalThis.ReadableStreamBYOBRequest = ReadableStreamBYOBRequest;
                }

                if (typeof globalThis.ReadableByteStreamController === "undefined") {
                    function ReadableByteStreamController() {
                        this.byobRequest = null;
                        this.desiredSize = 0;
                    }
                    ReadableByteStreamController.prototype.close = function() {};
                    ReadableByteStreamController.prototype.enqueue = function(chunk) {};
                    ReadableByteStreamController.prototype.error = function(e) {};
                    globalThis.ReadableByteStreamController = ReadableByteStreamController;
                }

                if (typeof globalThis.ReadableStreamDefaultController === "undefined") {
                    function ReadableStreamDefaultController() { this.desiredSize = 0; }
                    ReadableStreamDefaultController.prototype.close = function() {};
                    ReadableStreamDefaultController.prototype.enqueue = function(chunk) {};
                    ReadableStreamDefaultController.prototype.error = function(e) {};
                    globalThis.ReadableStreamDefaultController = ReadableStreamDefaultController;
                }

                if (typeof globalThis.WritableStream === "undefined") {
                    function WritableStream(underlyingSink, strategy) {
                        this.locked = false;
                        this._underlyingSink = underlyingSink || {};
                    }
                    WritableStream.prototype.getWriter = function() {
                        this.locked = true;
                        return new WritableStreamDefaultWriter(this);
                    };
                    WritableStream.prototype.abort = function(reason) { return Promise.resolve(); };
                    WritableStream.prototype.close = function() { return Promise.resolve(); };
                    globalThis.WritableStream = WritableStream;
                }

                if (typeof globalThis.WritableStreamDefaultWriter === "undefined") {
                    function WritableStreamDefaultWriter(stream) {
                        this._stream = stream;
                        this.closed = Promise.resolve();
                        this.ready = Promise.resolve();
                        this.desiredSize = 1;
                    }
                    WritableStreamDefaultWriter.prototype.write = function(chunk) { return Promise.resolve(); };
                    WritableStreamDefaultWriter.prototype.close = function() { return Promise.resolve(); };
                    WritableStreamDefaultWriter.prototype.abort = function(reason) { return Promise.resolve(); };
                    WritableStreamDefaultWriter.prototype.releaseLock = function() {
                        if (this._stream) this._stream.locked = false;
                    };
                    globalThis.WritableStreamDefaultWriter = WritableStreamDefaultWriter;
                }

                if (typeof globalThis.WritableStreamDefaultController === "undefined") {
                    function WritableStreamDefaultController() { this.signal = new AbortSignal(); }
                    WritableStreamDefaultController.prototype.error = function(e) {};
                    globalThis.WritableStreamDefaultController = WritableStreamDefaultController;
                }

                if (typeof globalThis.TransformStream === "undefined") {
                    function TransformStream(transformer, writableStrategy, readableStrategy) {
                        this.readable = new ReadableStream();
                        this.writable = new WritableStream();
                    }
                    globalThis.TransformStream = TransformStream;
                }

                if (typeof globalThis.TransformStreamDefaultController === "undefined") {
                    function TransformStreamDefaultController() { this.desiredSize = 0; }
                    TransformStreamDefaultController.prototype.enqueue = function(chunk) {};
                    TransformStreamDefaultController.prototype.error = function(reason) {};
                    TransformStreamDefaultController.prototype.terminate = function() {};
                    globalThis.TransformStreamDefaultController = TransformStreamDefaultController;
                }

                if (typeof globalThis.ByteLengthQueuingStrategy === "undefined") {
                    function ByteLengthQueuingStrategy(init) {
                        this.highWaterMark = (init && init.highWaterMark) || 0;
                    }
                    ByteLengthQueuingStrategy.prototype.size = function(chunk) {
                        return chunk && chunk.byteLength ? chunk.byteLength : 0;
                    };
                    globalThis.ByteLengthQueuingStrategy = ByteLengthQueuingStrategy;
                }

                if (typeof globalThis.CountQueuingStrategy === "undefined") {
                    function CountQueuingStrategy(init) {
                        this.highWaterMark = (init && init.highWaterMark) || 1;
                    }
                    CountQueuingStrategy.prototype.size = function() { return 1; };
                    globalThis.CountQueuingStrategy = CountQueuingStrategy;
                }

                // ---- TextDecoderStream / TextEncoderStream ----
                if (typeof globalThis.TextDecoderStream === "undefined") {
                    function TextDecoderStream(label, options) {
                        this.encoding = label || "utf-8";
                        this.readable = new ReadableStream();
                        this.writable = new WritableStream();
                    }
                    globalThis.TextDecoderStream = TextDecoderStream;
                }

                if (typeof globalThis.TextEncoderStream === "undefined") {
                    function TextEncoderStream() {
                        this.encoding = "utf-8";
                        this.readable = new ReadableStream();
                        this.writable = new WritableStream();
                    }
                    globalThis.TextEncoderStream = TextEncoderStream;
                }

                // ---- CompressionStream / DecompressionStream ----
                if (typeof globalThis.CompressionStream === "undefined") {
                    function CompressionStream(format) {
                        this.readable = new ReadableStream();
                        this.writable = new WritableStream();
                    }
                    globalThis.CompressionStream = CompressionStream;
                }

                if (typeof globalThis.DecompressionStream === "undefined") {
                    function DecompressionStream(format) {
                        this.readable = new ReadableStream();
                        this.writable = new WritableStream();
                    }
                    globalThis.DecompressionStream = DecompressionStream;
                }

                // ---- BroadcastChannel ----
                if (typeof globalThis.BroadcastChannel === "undefined") {
                    function BroadcastChannel(name) {
                        this.name = name;
                        this.onmessage = null;
                        this.onmessageerror = null;
                    }
                    BroadcastChannel.prototype.postMessage = function(message) {};
                    BroadcastChannel.prototype.close = function() {};
                    globalThis.BroadcastChannel = BroadcastChannel;
                }

                // ---- MessageChannel / MessagePort ----
                if (typeof globalThis.MessagePort === "undefined") {
                    function MessagePort() {
                        this.onmessage = null;
                        this.onmessageerror = null;
                    }
                    MessagePort.prototype.postMessage = function(message, transfer) {};
                    MessagePort.prototype.start = function() {};
                    MessagePort.prototype.close = function() {};
                    globalThis.MessagePort = MessagePort;
                }

                if (typeof globalThis.MessageChannel === "undefined") {
                    function MessageChannel() {
                        this.port1 = new MessagePort();
                        this.port2 = new MessagePort();
                    }
                    globalThis.MessageChannel = MessageChannel;
                }

                // ---- EventSource ----
                if (typeof globalThis.EventSource === "undefined") {
                    function EventSource(url, eventSourceInitDict) {
                        this.url = url;
                        this.readyState = 2; // CLOSED
                        this.onopen = null;
                        this.onmessage = null;
                        this.onerror = null;
                    }
                    EventSource.CONNECTING = 0;
                    EventSource.OPEN = 1;
                    EventSource.CLOSED = 2;
                    EventSource.prototype.close = function() { this.readyState = 2; };
                    globalThis.EventSource = EventSource;
                }

                // ---- WebSocket ----
                if (typeof globalThis.WebSocket === "undefined") {
                    function WebSocket(url, protocols) {
                        this.url = url;
                        this.readyState = 3; // CLOSED
                        this.protocol = "";
                        this.extensions = "";
                        this.bufferedAmount = 0;
                        this.binaryType = "blob";
                        this.onopen = null;
                        this.onclose = null;
                        this.onmessage = null;
                        this.onerror = null;
                    }
                    WebSocket.CONNECTING = 0;
                    WebSocket.OPEN = 1;
                    WebSocket.CLOSING = 2;
                    WebSocket.CLOSED = 3;
                    WebSocket.prototype.send = function(data) {
                        throw new DOMException("WebSocket is not connected", "InvalidStateError");
                    };
                    WebSocket.prototype.close = function(code, reason) { this.readyState = 3; };
                    globalThis.WebSocket = WebSocket;
                }

                // ---- Worker ----
                if (typeof globalThis.Worker === "undefined") {
                    function Worker(scriptURL, options) {
                        throw new DOMException("Worker is not supported in Denox", "NotSupportedError");
                    }
                    globalThis.Worker = Worker;
                }

                // ---- Cache / CacheStorage / caches ----
                if (typeof globalThis.Cache === "undefined") {
                    function Cache() {}
                    var notImpl = function() { return Promise.reject(new DOMException("Cache API not supported", "NotSupportedError")); };
                    Cache.prototype.match = notImpl;
                    Cache.prototype.matchAll = notImpl;
                    Cache.prototype.add = notImpl;
                    Cache.prototype.addAll = notImpl;
                    Cache.prototype.put = notImpl;
                    Cache.prototype.delete = notImpl;
                    Cache.prototype.keys = notImpl;
                    globalThis.Cache = Cache;
                }

                if (typeof globalThis.CacheStorage === "undefined") {
                    function CacheStorage() {}
                    var csNotImpl = function() { return Promise.reject(new DOMException("CacheStorage not supported", "NotSupportedError")); };
                    CacheStorage.prototype.match = csNotImpl;
                    CacheStorage.prototype.has = csNotImpl;
                    CacheStorage.prototype.open = csNotImpl;
                    CacheStorage.prototype.delete = csNotImpl;
                    CacheStorage.prototype.keys = csNotImpl;
                    globalThis.CacheStorage = CacheStorage;
                }

                if (typeof globalThis.caches === "undefined") {
                    globalThis.caches = new CacheStorage();
                }

                // ---- URLPattern ----
                if (typeof globalThis.URLPattern === "undefined") {
                    function URLPattern(input, baseURL) {
                        this._input = input;
                        this._baseURL = baseURL;
                    }
                    URLPattern.prototype.test = function(input, baseURL) { return false; };
                    URLPattern.prototype.exec = function(input, baseURL) { return null; };
                    globalThis.URLPattern = URLPattern;
                }

                // ---- ImageBitmap / ImageData ----
                if (typeof globalThis.ImageBitmap === "undefined") {
                    function ImageBitmap(width, height) {
                        this.width = width || 0;
                        this.height = height || 0;
                    }
                    ImageBitmap.prototype.close = function() {};
                    globalThis.ImageBitmap = ImageBitmap;
                }

                if (typeof globalThis.ImageData === "undefined") {
                    function ImageData(dataOrWidth, heightOrSettings, settings) {
                        if (typeof dataOrWidth === "number") {
                            this.width = dataOrWidth;
                            this.height = heightOrSettings || 0;
                            this.data = new Uint8ClampedArray(this.width * this.height * 4);
                        } else {
                            this.data = dataOrWidth;
                            this.width = heightOrSettings || 0;
                            this.height = (settings && settings.height) || (this.data.length / (this.width * 4));
                        }
                        this.colorSpace = "srgb";
                    }
                    globalThis.ImageData = ImageData;
                }

                if (typeof globalThis.createImageBitmap === "undefined") {
                    globalThis.createImageBitmap = function() {
                        return Promise.reject(new DOMException("createImageBitmap not supported", "NotSupportedError"));
                    };
                }

                // ---- SuppressedError ----
                if (typeof globalThis.SuppressedError === "undefined") {
                    function SuppressedError(error, suppressed, message) {
                        var e = new Error(message);
                        e.name = "SuppressedError";
                        e.error = error;
                        e.suppressed = suppressed;
                        return e;
                    }
                    globalThis.SuppressedError = SuppressedError;
                }

                // ---- DisposableStack / AsyncDisposableStack ----
                if (typeof globalThis.DisposableStack === "undefined") {
                    function DisposableStack() {
                        this._disposed = false;
                        this._stack = [];
                    }
                    DisposableStack.prototype.dispose = function() {
                        if (this._disposed) return;
                        this._disposed = true;
                        for (var i = this._stack.length - 1; i >= 0; i--) {
                            try { this._stack[i](); } catch(e) {}
                        }
                    };
                    DisposableStack.prototype.use = function(value) {
                        if (value != null && typeof value[Symbol.dispose] === "function") {
                            this._stack.push(function() { value[Symbol.dispose](); });
                        }
                        return value;
                    };
                    DisposableStack.prototype.adopt = function(value, onDispose) {
                        this._stack.push(function() { onDispose(value); });
                        return value;
                    };
                    DisposableStack.prototype.defer = function(onDispose) {
                        this._stack.push(onDispose);
                    };
                    DisposableStack.prototype.move = function() {
                        var newStack = new DisposableStack();
                        newStack._stack = this._stack;
                        this._stack = [];
                        return newStack;
                    };
                    Object.defineProperty(DisposableStack.prototype, "disposed", {
                        get: function() { return this._disposed; }
                    });
                    globalThis.DisposableStack = DisposableStack;
                }

                if (typeof globalThis.AsyncDisposableStack === "undefined") {
                    function AsyncDisposableStack() {
                        this._disposed = false;
                        this._stack = [];
                    }
                    AsyncDisposableStack.prototype.disposeAsync = async function() {
                        if (this._disposed) return;
                        this._disposed = true;
                        for (var i = this._stack.length - 1; i >= 0; i--) {
                            try { await this._stack[i](); } catch(e) {}
                        }
                    };
                    AsyncDisposableStack.prototype.use = function(value) {
                        if (value != null) {
                            var dispose = value[Symbol.asyncDispose] || value[Symbol.dispose];
                            if (typeof dispose === "function") {
                                this._stack.push(function() { return dispose.call(value); });
                            }
                        }
                        return value;
                    };
                    AsyncDisposableStack.prototype.adopt = function(value, onDispose) {
                        this._stack.push(function() { return onDispose(value); });
                        return value;
                    };
                    AsyncDisposableStack.prototype.defer = function(onDispose) {
                        this._stack.push(onDispose);
                    };
                    AsyncDisposableStack.prototype.move = function() {
                        var newStack = new AsyncDisposableStack();
                        newStack._stack = this._stack;
                        this._stack = [];
                        return newStack;
                    };
                    Object.defineProperty(AsyncDisposableStack.prototype, "disposed", {
                        get: function() { return this._disposed; }
                    });
                    globalThis.AsyncDisposableStack = AsyncDisposableStack;
                }

                // ---- GPU stubs ----
                var gpuNames = [
                    "GPU", "GPUAdapter", "GPUAdapterInfo", "GPUBindGroup", "GPUBindGroupLayout",
                    "GPUBuffer", "GPUBufferUsage", "GPUCanvasContext", "GPUColorWrite",
                    "GPUCommandBuffer", "GPUCommandEncoder", "GPUCompilationInfo", "GPUCompilationMessage",
                    "GPUComputePassEncoder", "GPUComputePipeline", "GPUDevice", "GPUDeviceLostInfo",
                    "GPUError", "GPUInternalError", "GPUMapMode", "GPUOutOfMemoryError",
                    "GPUPipelineError", "GPUPipelineLayout", "GPUQuerySet", "GPUQueue",
                    "GPURenderBundle", "GPURenderBundleEncoder", "GPURenderPassEncoder",
                    "GPURenderPipeline", "GPUSampler", "GPUShaderModule", "GPUShaderStage",
                    "GPUSupportedFeatures", "GPUSupportedLimits", "GPUTexture", "GPUTextureUsage",
                    "GPUTextureView", "GPUUncapturedErrorEvent", "GPUValidationError"
                ];
                for (var gi = 0; gi < gpuNames.length; gi++) {
                    if (typeof globalThis[gpuNames[gi]] === "undefined") {
                        globalThis[gpuNames[gi]] = function() {
                            throw new DOMException("WebGPU is not supported in Denox", "NotSupportedError");
                        };
                    }
                }
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
                        process_eval(&mut runtime, &tokio_rt, code, transpile)
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
                    // Use a unique specifier per eval to avoid module cache collisions
                    static COUNTER: std::sync::atomic::AtomicU64 =
                        std::sync::atomic::AtomicU64::new(0);
                    let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    let spec = deno_core::url::Url::from_file_path(
                        base.join(format!("__denox_eval_async_{n}.js")),
                    )
                    .unwrap_or_else(|_| {
                        deno_core::url::Url::parse(&format!(
                            "file:///denox_eval_async_{n}.js"
                        ))
                        .unwrap()
                    });

                    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        process_eval_module_code(
                            &mut runtime,
                            &tokio_rt,
                            code,
                            transpile,
                            &spec,
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
