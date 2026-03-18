use deno_core::op2;
use serde::Serialize;
use std::io::Read;

#[derive(Serialize)]
pub struct FetchResponse {
    pub status: u16,
    pub status_text: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

/// Async op that performs an HTTP request using ureq.
/// Called from JS as `await Deno.core.ops.op_fetch(url, method, headers, body)`.
#[op2(async)]
#[serde]
pub async fn op_fetch(
    #[string] url: String,
    #[string] method: String,
    #[serde] headers: Vec<(String, String)>,
    #[serde] body: Option<Vec<u8>>,
) -> Result<FetchResponse, deno_core::error::AnyError> {
    // ureq is synchronous, so run in a blocking task to avoid blocking the
    // tokio current_thread event loop.
    tokio::task::spawn_blocking(move || {
        let mut req = match method.to_uppercase().as_str() {
            "POST" => ureq::post(&url),
            "PUT" => ureq::put(&url),
            "DELETE" => ureq::delete(&url),
            "PATCH" => ureq::patch(&url),
            "HEAD" => ureq::head(&url),
            _ => ureq::get(&url),
        };

        for (key, value) in &headers {
            req = req.set(key, value);
        }

        let response = match body {
            Some(ref b) => req.send_bytes(b),
            None => req.call(),
        };

        match response {
            Ok(resp) => response_to_fetch_response(resp),
            Err(ureq::Error::Status(_code, resp)) => {
                // HTTP error status (4xx, 5xx) — still a valid response for fetch
                response_to_fetch_response(resp)
            }
            Err(ureq::Error::Transport(e)) => Err(deno_core::error::generic_error(format!(
                "TypeError: fetch failed: {}",
                e
            ))),
        }
    })
    .await
    .map_err(|e| deno_core::error::generic_error(format!("fetch task failed: {}", e)))?
}

fn response_to_fetch_response(
    resp: ureq::Response,
) -> Result<FetchResponse, deno_core::error::AnyError> {
    let status = resp.status();
    let status_text = resp.status_text().to_string();

    let mut headers = Vec::new();
    for name in resp.headers_names() {
        if let Some(value) = resp.header(&name) {
            headers.push((name, value.to_string()));
        }
    }

    let mut body = Vec::new();
    resp.into_reader().read_to_end(&mut body).map_err(|e| {
        deno_core::error::generic_error(format!("Failed to read response body: {}", e))
    })?;

    Ok(FetchResponse {
        status,
        status_text,
        headers,
        body,
    })
}

deno_core::extension!(denox_fetch_ext, ops = [op_fetch],);
