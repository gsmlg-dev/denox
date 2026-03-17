use deno_core::op2;
use std::time::Instant;

/// Returns elapsed milliseconds since an arbitrary epoch (process start) as f64.
/// Used to back `performance.now()` in JavaScript.
#[op2(fast)]
pub fn op_hrtime_now(#[state] start: &Instant) -> f64 {
    start.elapsed().as_secs_f64() * 1000.0
}

/// Fills a byte buffer with cryptographically secure random bytes.
/// Used to back `crypto.getRandomValues()` in JavaScript.
#[op2(fast)]
pub fn op_crypto_random(#[buffer] buf: &mut [u8]) {
    getrandom::getrandom(buf).expect("getrandom failed");
}

deno_core::extension!(
    denox_globals_ext,
    ops = [op_hrtime_now, op_crypto_random],
    state = |state| {
        state.put(Instant::now());
    },
);
