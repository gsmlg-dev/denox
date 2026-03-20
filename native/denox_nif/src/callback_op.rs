use std::sync::mpsc;

/// A callback request sent from the V8 thread to the NIF caller.
pub struct CallbackRequest {
    pub id: u64,
    pub name: String,
    pub args_json: String,
    pub reply_tx: mpsc::Sender<Result<String, String>>,
}

/// State stored alongside the V8 runtime for callback support.
pub struct CallbackState {
    pub request_tx: mpsc::Sender<CallbackRequest>,
    pub next_id: std::sync::atomic::AtomicU64,
}

/// Install `globalThis.Denox.callback(name, ...args)` as a V8 function.
///
/// This approach bypasses deno_core's op system because MainWorker's snapshot
/// freezes the `core.ops` table and custom ops added via extensions are not
/// exposed to JS. Instead, we bind a V8 function directly that accesses
/// the CallbackState through a V8 external.
pub fn install_callback_global(
    runtime: &mut deno_core::JsRuntime,
    state: CallbackState,
) {
    let scope = &mut runtime.handle_scope();

    // Store the CallbackState on the heap and wrap it in a V8 External
    let state_box = Box::new(state);
    let state_ptr = Box::into_raw(state_box);
    let external = deno_core::v8::External::new(scope, state_ptr as *mut std::ffi::c_void);

    // Create the callback function
    let callback_fn = deno_core::v8::Function::builder(denox_callback_v8)
        .data(external.into())
        .build(scope)
        .expect("Failed to create Denox.callback function");

    // Create the Denox object and set the callback function on it
    let denox_obj = deno_core::v8::Object::new(scope);
    let key = deno_core::v8::String::new(scope, "callback").unwrap();
    denox_obj.set(scope, key.into(), callback_fn.into());

    // Set globalThis.Denox = { callback: fn }
    let global = scope.get_current_context().global(scope);
    let denox_key = deno_core::v8::String::new(scope, "Denox").unwrap();
    global.set(scope, denox_key.into(), denox_obj.into());
}

/// V8 callback function implementation.
/// Called from JS as: Denox.callback("name", arg1, arg2, ...)
fn denox_callback_v8(
    scope: &mut deno_core::v8::HandleScope,
    args: deno_core::v8::FunctionCallbackArguments,
    mut retval: deno_core::v8::ReturnValue,
) {
    // Extract the CallbackState from the V8 External data
    let data = args.data();
    let external = unsafe {
        deno_core::v8::Local::<deno_core::v8::External>::cast_unchecked(data)
    };
    let state_ptr = external.value() as *mut CallbackState;
    let state = unsafe { &*state_ptr };

    // First argument is the callback name
    if args.length() < 1 {
        let msg = deno_core::v8::String::new(scope, "Denox.callback requires at least a name argument").unwrap();
        let exception = deno_core::v8::Exception::type_error(scope, msg);
        scope.throw_exception(exception);
        return;
    }

    let name_val = args.get(0);
    let name = name_val.to_rust_string_lossy(scope);

    // Collect remaining arguments into a JSON array
    let mut js_args = Vec::new();
    for i in 1..args.length() {
        let val = args.get(i);
        match deno_core::serde_v8::from_v8::<serde_json::Value>(scope, val) {
            Ok(json_val) => js_args.push(json_val),
            Err(_) => {
                let s = val.to_rust_string_lossy(scope);
                js_args.push(serde_json::Value::String(s));
            }
        }
    }
    let args_json = serde_json::to_string(&js_args).unwrap_or_else(|_| "[]".to_string());

    // Get next callback ID
    let id = state
        .next_id
        .fetch_add(1, std::sync::atomic::Ordering::SeqCst);

    // Create reply channel
    let (reply_tx, reply_rx) = mpsc::channel();

    // Send the request to the NIF caller
    if let Err(_) = state.request_tx.send(CallbackRequest {
        id,
        name,
        args_json,
        reply_tx,
    }) {
        let msg = deno_core::v8::String::new(scope, "Callback channel closed — no callback handler registered").unwrap();
        let exception = deno_core::v8::Exception::error(scope, msg);
        scope.throw_exception(exception);
        return;
    }

    // Block until the NIF caller processes the callback and sends the result
    match reply_rx.recv() {
        Ok(Ok(result_json)) => {
            // Parse the result JSON and return the value
            let json_str = deno_core::v8::String::new(scope, &result_json).unwrap();
            let parsed = deno_core::v8::json::parse(scope, json_str.into());
            match parsed {
                Some(val) => retval.set(val),
                None => {
                    // If JSON parsing fails, return as string
                    retval.set(json_str.into());
                }
            }
        }
        Ok(Err(error_msg)) => {
            let msg = deno_core::v8::String::new(scope, &error_msg).unwrap();
            let exception = deno_core::v8::Exception::error(scope, msg);
            scope.throw_exception(exception);
        }
        Err(_) => {
            let msg = deno_core::v8::String::new(scope, "Callback reply channel closed").unwrap();
            let exception = deno_core::v8::Exception::error(scope, msg);
            scope.throw_exception(exception);
        }
    }
}
