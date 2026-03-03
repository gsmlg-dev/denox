use deno_core::op2;
use deno_core::OpState;
use std::sync::mpsc;

/// A callback request sent from the V8 thread to the NIF caller.
pub struct CallbackRequest {
    pub id: u64,
    pub name: String,
    pub args_json: String,
    pub reply_tx: mpsc::Sender<Result<String, String>>,
}

/// State stored in deno_core OpState for the callback op.
pub struct CallbackState {
    pub request_tx: mpsc::Sender<CallbackRequest>,
    pub next_id: std::sync::atomic::AtomicU64,
}

/// Synchronous op callable from JS as `Deno.core.ops.op_elixir_call(name, args_json)`.
/// Blocks the V8 thread until the Elixir side handles the callback and sends a reply.
#[op2]
#[string]
pub fn op_elixir_call(
    state: &mut OpState,
    #[string] name: String,
    #[string] args_json: String,
) -> Result<String, deno_core::error::AnyError> {
    let cb_state = state.borrow::<CallbackState>();
    let id = cb_state
        .next_id
        .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    let (reply_tx, reply_rx) = mpsc::channel();

    cb_state
        .request_tx
        .send(CallbackRequest {
            id,
            name,
            args_json,
            reply_tx,
        })
        .map_err(|_| anyhow::anyhow!("Callback channel closed — no callback handler registered"))?;

    // Block until the NIF caller processes the callback and sends the result
    let result = reply_rx
        .recv()
        .map_err(|_| anyhow::anyhow!("Callback reply channel closed"))?;

    result.map_err(|e| anyhow::anyhow!("{}", e))
}

deno_core::extension!(
    denox_callback_ext,
    ops = [op_elixir_call],
);
