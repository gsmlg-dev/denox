## v0.6.0 (latest)

### Changes (since previous release)

- fix: `Denox.Deps.add_to_config/3` and `remove_from_config/2` now return
  `{:error, "Failed to write ..."}` (human-readable string) instead of
  `{:error, :eacces}` (raw posix atom) when the config file is not writable
- test: add `Denox.Deps.add/3` write failure test — verifies that readonly config
  files produce a readable error string, not a raw posix error atom
- test: add `Denox.Deps.runtime/1` empty import_map branch coverage — exercises
  the `map_size == 0` conditional skip in the runtime builder
- test: add `CallbackHandler` non-JSON-serializable return value test — verifies that
  when a callback function returns a value that cannot be JSON-encoded (e.g., a PID),
  the `rescue` clause catches the `JSON.EncodeError` and sends it to JS as an error
  tuple rather than crashing the handler
- test: add `stream/1` RuntimeError test — verifies that when `start_link` fails
  (e.g., neither `:file` nor `:package` provided), the stream raises `RuntimeError`
  when enumerated, as documented in the `@doc` warning block
- fix(test): replace flaky `Application.stop(:inets)` test in coverage_gaps_test.exs
  with a safe synchronous test — the dangerous global state mutation was intermittently
  causing TLS errors in concurrently running async test modules
- test: add `Denox.CLI.find_deno/0` system PATH success test — verifies system deno
  binary is found and returned as `{:ok, path}` when present on PATH, taking priority
  over the bundled CLI (exercises the first branch of the 3-step fallback chain)
- test: add `Denox.CLI.handle_response/2` edge case coverage — `:exit` reason tuples
  (e.g., connection refused caught by `download/2`) and non-200 responses with empty
  body are both handled and produce readable error messages
- test: add `unsubscribe/1` idempotency tests — unsubscribing a PID that was never
  subscribed, and calling unsubscribe twice after one subscribe, both return `:ok`
  without error (verified against `Denox.Run.Base.__handle_call__/4` logic)
- test: add `stream_from/2` edge case — empty list returned when server exits
  immediately without producing any output (complements `stream/1` no-output test)
- fix(rust): log unexpected I/O errors in stdout pipe reader thread instead of
  silently discarding them; normal pipe-close errors (BrokenPipe, UnexpectedEof)
  remain silent as they are expected on runtime exit

- refactor: extract `Denox.Permissions` module to centralize NIF permission JSON
  building — eliminates duplicate `@valid_permission_keys` and `build_permissions_json`
  between `Denox` and `Denox.Run`
- refactor: deduplicate `ts_extension?/1` between `Denox` and `Denox.Pool`
- test: add unit tests for `Denox.Permissions` (8 tests covering all code paths)
- test: add permission enforcement tests verifying Deno actually restricts env and
  file read access under `permissions: :none` and allows under `:all` / granular

- fix: tag deno-dependent tests with `:deno` to skip in CI
- fix(ci): set `MIX_ENV=test` for E2E workflow
- refactor: replace JS polyfill I/O with native `deno_io` pipe bridging in `runtime_run`
- refactor: extract `RuntimeRunResource` and NIF functions into `runtime_run.rs`
- fix: add panic safety (`catch_unwind`) to runtime threads

- chore: add `@spec` annotations to callback implementations in `Denox.Run`,
  `Denox.CLI.Run`, and `Denox.CallbackHandler`
- chore: add `@spec` to injected GenServer callbacks (`init/1`, `handle_call/3`,
  `dispatch_line/2`, `handle_exit/2`) in `Denox.Run.Base`
- chore: add `@spec` to private helpers in `Denox.Pool` and `Denox.CLI.Run`
- feat: validate unknown granular permission keys in `Denox.runtime/1` and
  `Denox.Run.start_link/1` — raises `ArgumentError` instead of silently ignoring
- feat: move permission validation before CLI lookup in `Denox.CLI.Run.init_backend/1`
  so callers get `ArgumentError` before any binary search
- test: add `deny_*` permission tests for both `Denox.Run` (NIF) and `Denox.CLI.Run`
  (subprocess) backends
- test: add Pool error-path tests for `eval_file`, `eval_file_decode`, `eval_module`,
  `exec`, `exec_ts`, and `call`/`call_async` with undefined functions
- test: add `with_runtime/2` error-passthrough test (user function returning `{:error, ...}`)
- docs: document `deny_*` keys and `ArgumentError` in `Denox.runtime/1` `:permissions` option
- docs: expand `Denox.Pool` moduledoc with `load_npm` and `exec` usage patterns
- docs: clarify `exec/2` and `exec_ts/2`: errors must still be handled (not fire-and-forget)
- docs: document `with_runtime/2` error-passthrough semantics
- docs: clarify `Denox.CLI.Run` primary use case is npm/jsr packages

- fix: `Denox.Pool.init/1` now returns `{:stop, {:failed_to_create_runtime, msg}}`
  instead of raising when runtime creation fails — enables proper supervision tree
  error propagation
- fix: `Denox.Run.Base` `subscribe/1` now deduplicates by PID — calling subscribe
  twice from the same process no longer creates duplicate monitor refs or sends
  duplicate stdout messages
- fix: `Denox.Permissions.to_nif_json/1` now raises `ArgumentError` on unknown
  permission keys even when the value is `false` (previously silently ignored)
- test: add duplicate subscribe idempotency test
- test: add Pool init failure propagation test
- test: add CLI.Run invalid env type validation test
- test: add permission edge case tests (mixed allow/deny, empty lists, false unknown keys)

### Improvements

- `Denox.Run` stdin/stdout now uses native OS pipe bridging via `deno_io::Stdio`/`StdioPipe`
  instead of JS-level polyfills. This eliminates the 10ms busy-poll loop for stdin reads,
  removes the `console.log` override, and implements the PRD-specified 2N+1 thread model
  (event loop + pipe reader + pipe writer).
- `Denox.Run.Base` now has a proper `@moduledoc` documenting the shared behaviour
  contract (`init_backend/1`, `send_backend/2`, `stop_backend/1`, `alive_backend?/1`)
  for backend implementors.
- `Denox.Run` documentation now explicitly states that `npm:` and `jsr:` specifiers
  are **not supported** by the NIF backend (TsModuleLoader only handles `file://`,
  `https://`, and `http://` schemes). Users are directed to `Denox.CLI.Run` for
  npm/jsr packages.
- Test coverage expanded: pipe I/O edge cases (empty lines, Unicode, `Deno.stdout.write`,
  long lines, rapid output), Web Streams API, `Blob`, `MessageChannel`, Promise
  combinators, `setTimeout`/`setInterval`, granular permissions enforcement.
- PRD checklist fully verified (29/29 items passing).
- `capture/1` convenience function added to `Denox.Run.Base` (and inherited by both
  `Denox.Run` and `Denox.CLI.Run`): starts a runtime, collects all stdout lines until
  exit or timeout, and returns them as `{:ok, [String.t()]}`. Uses the recv-poll pattern
  to avoid subscribe race conditions on fast-completing scripts.
- `stream/1` convenience function added to `Denox.Run.Base`: returns a lazy
  `Stream.resource/3` enumerable that yields stdout lines one-by-one, suitable for
  large or streaming output. Halts on process exit or timeout.
- `send_and_recv/3` convenience function added to `Denox.Run.Base`: one-shot
  request/response helper for JSON-RPC over stdio (e.g. MCP servers). Sends a line
  and returns the next line, wrapping `send/2` + `recv/2` in a single call.
- `stream_from/2` convenience function added to `Denox.Run.Base`: returns a lazy
  `Stream.resource/3` enumerable from an **already-running** server PID. Unlike
  `stream/1`, it does not start or stop the server — the caller retains ownership.
  Pairs naturally with `with_runtime/2` for request-response workflows.
- `with_runtime/2` bracket-style resource management added to `Denox.Run.Base`:
  starts a runtime, passes the PID to a user function, and guarantees cleanup via
  an `after` block — even if the function raises. Returns `{:error, reason}` if
  the runtime fails to start.

## v0.5.0 — 2026-03-22

### Features

- **`Denox.Run` NIF backend** — replaced subprocess `deno run` with an in-process `deno_runtime` MainWorker via Rustler NIF. No external `deno` binary required for `Denox.Run`. Supports stdin/stdout streaming, telemetry, OTP supervision, and all permission modes.
- **`Denox.CLI` binary manager** — downloads and caches the official Deno binary for the current platform (macOS/Linux, x86_64/aarch64). Configure with `config :denox, :cli, version: "2.x.x"` and run `mix denox.cli.install`.
- **`Denox.CLI.Run`** — subprocess-based runner using the bundled CLI binary; same API as `Denox.Run` but spawns a `deno` process per instance. Useful when full CLI features are needed.
- **Shared `Run.Base` behaviour** — shared GenServer dispatch logic extracted as a `__using__` macro behaviour, supporting both NIF and CLI backends with a common `send/recv/subscribe/unsubscribe/alive?/stop` API.
- **Granular permissions** — both `Denox.Run` and `Denox.CLI.Run` support `:all`, `nil`/`:none`, or a keyword list of `allow_*`/`deny_*` permission flags.
- **Telemetry** — `[:denox, :run, :start]`, `[:denox, :run, :stop]`, `[:denox, :run, :recv]` events emitted for all backends.

### Fixes

- `deno_core` replaced with `deno_runtime` MainWorker for full Deno API compatibility (fetch, timers, Deno.env, etc.)
- Monitor leak on `unsubscribe/1`: monitors are now properly demonitored when subscribers unsubscribe
- Stale `recv_waiters` on timeout: timed-out `recv/2` callers are now monitored; dead waiters are removed before dispatching lines
- `mix denox.run` now uses `Denox.CLI.find_deno()` for bundled CLI fallback, consistent with `Denox.Deps` and `Denox.Npm`
- `mix denox.run` drains remaining port messages after exit_status to prevent dropping final output without trailing newline (race condition on Linux where `{:exit_status, 0}` arrives before `{:noeol, chunk}`)
- `Denox.Deps.ensure_vendor_config/1` refactored to reduce nesting depth
- File write errors in `Denox.Deps.ensure_vendor_config` now include the filename in the error message
- `send/2` documentation updated to document automatic newline appending and `{:error, :closed}` return
- `Denox.CLI.Run` now documents the `:deno_flags` option for passing extra flags to `deno run`

## v0.4.1

### Features

- Added 206 comprehensive web/Node.js global polyfills
- Added `globalThis.fetch` polyfill with Headers/Request/Response

### Fixes

- Added `:mix` to Dialyzer PLT apps for Mix.Task modules
- Added credo and dialyxir deps, resolved all credo issues
- Added Rust toolchain and `DENOX_BUILD` to CI workflow
- Fixed hello script and cleaned up .envrc


## v0.4.0

### Features

- **`Denox.Run` subprocess runner** — GenServer wrapping `deno run` with bidirectional stdio, enabling Elixir apps to run full Deno programs (MCP servers, CLI tools) with OTP supervision
- **`mix denox.run` task** — drop-in replacement for `deno run` with stdin forwarding, e.g. `mix denox.run -A @modelcontextprotocol/server-github`
- **Deno permission mapping** — `:all` for `-A`, or granular keyword list (`allow_net`, `allow_env`, etc.)
- **Auto npm: prefix** — bare `@scope/name` specifiers are automatically prefixed with `npm:`
- **Pub/sub stdout** — `Denox.Run.subscribe/1` for receiving `{:denox_run_stdout, pid, line}` messages
- **Real `setTimeout`** — native `op_sleep` async op for millisecond-accurate delays in `setTimeout`/`setInterval`
- **Convenience functions** — added `eval_async_decode`, `eval_ts_async_decode`, `eval_file_async`, `eval_file_decode`, `eval_file_async_decode` for cleaner API

### Fixes

- Fixed `setTimeout` returning immediately instead of waiting for the specified delay

## v0.3.0

### Breaking Changes

- `Denox.eval_async/2`, `Denox.eval_ts_async/2`, `Denox.call_async/3`, `Denox.call_async_decode/3` now return `Task.t()` instead of `{:ok, result} | {:error, message}`. Call `Denox.await(task)` to get the result.
- `Denox.eval/2` now pumps the event loop (supports Promises and dynamic imports in sync mode)

### Features

- **Unified event loop pumping** — all eval modes now pump the event loop, making sync and async consistent
- **Task-based async API** — true concurrency with proper task management
- **`Denox.await/2` helper** — delegates to `Task.await` for convenience

### Playground Enhancements

- Added Preact JSX SSR demo with real JSX syntax support
- Added import map example showing bare specifier resolution
- Display import map content above code editor
- Fixed async examples to handle long CDN fetches without timing out

## v0.2.2

### Features

- **JSX/TSX transpilation** — changed from `MediaType::TypeScript` to `MediaType::Tsx` for native JSX support
- **`setTimeout` polyfill** — async-safe timer polyfill for microtask-based delays
- **Preact SSR example** — server-side rendering via `preact-render-to-string`

### Playground

- 12 example snippets including Preact JSX SSR demo
- CDN imports from esm.sh, esm.run, jsr
- Zod schema validation example

## v0.2.1

### Features

- **Multiple CDN examples** — lodash, Zod, JSR packages
- **Import map support** — `Denox.runtime(import_map: %{...})` for bare specifier resolution
- **Timer polyfill** — basic `setTimeout`/`setInterval` (microtask-based, no real delays)

### Playground

- 10 example snippets
- Language toggle (JS/TS)
- Mode toggle (Sync/Async)
- Execution history with accordion view
- Theme switcher

## v0.1.0

Initial release.

### Features

- **JavaScript evaluation** — sub-millisecond V8 eval via `deno_core` 0.311
- **TypeScript transpilation** — native swc/deno_ast, transpile-only (no type-checking)
- **ES module loading** — `import`/`export` between `.ts`/`.js` files with `eval_module/2`
- **Async evaluation** — `await`, dynamic `import()`, Promise resolution via `eval_async/2`
- **CDN imports** — fetch from esm.sh, esm.run, etc. with in-memory + disk caching
- **Dependency management** — `deno.json` + `mix denox.install` for npm/jsr packages
- **Pre-bundling** — `mix denox.bundle` and `Denox.Npm.load/2` for self-contained JS files
- **Runtime pool** — `Denox.Pool` GenServer with round-robin across N V8 isolates
- **Import maps** — bare specifier resolution via `:import_map` option
- **JS → Elixir callbacks** — `Denox.callback()` in JS, `Denox.CallbackHandler` GenServer
- **V8 snapshots** — `Denox.create_snapshot/2` for faster cold starts
- **Sandbox mode** — strip extensions for reduced attack surface
- **Telemetry** — `[:denox, :eval, :start | :stop | :exception]` events
- **Precompiled NIFs** — via RustlerPrecompiled for macOS and Linux (x86_64, aarch64)

### API

- `Denox.runtime/1` — create a V8 runtime with options
- `Denox.eval/2`, `Denox.eval_ts/2` — synchronous JS/TS evaluation
- `Denox.eval_async/2`, `Denox.eval_ts_async/2` — async evaluation (event loop)
- `Denox.exec/2`, `Denox.exec_ts/2` — evaluate, ignore return value
- `Denox.call/3`, `Denox.call_async/3` — call named JS functions
- `Denox.eval_decode/2`, `Denox.eval_ts_decode/2`, `Denox.call_decode/3`, `Denox.call_async_decode/3` — evaluate and decode JSON
- `Denox.eval_module/2` — load ES module files
- `Denox.eval_file/3` — read and evaluate JS/TS files
- `Denox.create_snapshot/2` — create V8 snapshots
- `Denox.Pool` — runtime pool for concurrent workloads
- `Denox.CallbackHandler` — JS → Elixir callback handler
- `Denox.Deps` — dependency management via deno CLI
- `Denox.Npm` — pre-bundled npm package loading
