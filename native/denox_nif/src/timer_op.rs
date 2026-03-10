use deno_core::op2;
use std::future::Future;
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

/// A future that completes after a given deadline, yielding Pending until then.
struct SleepFuture {
    deadline: Instant,
}

impl Future for SleepFuture {
    type Output = ();

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        if Instant::now() >= self.deadline {
            Poll::Ready(())
        } else {
            // Schedule a wakeup so we get polled again on the next event loop tick
            cx.waker().wake_by_ref();
            Poll::Pending
        }
    }
}

/// Async op that sleeps for the given number of milliseconds.
/// Called from JS as `await Deno.core.ops.op_sleep(ms)`.
#[op2(async)]
pub async fn op_sleep(#[bigint] ms: u64) {
    if ms == 0 {
        return;
    }
    SleepFuture {
        deadline: Instant::now() + Duration::from_millis(ms),
    }
    .await;
}

deno_core::extension!(denox_timer_ext, ops = [op_sleep],);
