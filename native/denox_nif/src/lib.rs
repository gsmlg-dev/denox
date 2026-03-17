mod callback_op;
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

            // Register globals extension (performance.now, crypto.getRandomValues)
            opts.extensions
                .push(globals_op::denox_globals_ext::init_ops());

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
