# PRD: Deno Runtime Migration & CLI Runner

**Date:** 2026-03-20
**Status:** Draft
**Scope:** Rust NIF (`native/denox_nif/`), Elixir modules (`lib/denox/`)

---

## Problem

`Denox.Run` currently requires the `deno` CLI installed globally. This creates a runtime dependency and limits where Denox can be deployed. Additionally, the NIF uses bare `deno_core` with ~2000 lines of hand-written JS polyfills for Web APIs (`setTimeout`, `fetch`, `console`, `crypto`, `URL`, `TextEncoder`, `Buffer`, `process`, etc.), which are incomplete and maintenance-heavy.

## Solution

Two complementary changes:

1. **Replace `deno_core` with `deno_runtime`** — gives all existing eval/call functions full Deno APIs natively, eliminates custom polyfills, and enables a new NIF-backed `Denox.Run`
2. **Bundle the Deno CLI binary** — `tailwind`/`esbuild`-style download for a subprocess-based `Denox.CLI.Run`, disabled by default, used primarily for testing

---

## Part 1: `deno_core` → `deno_runtime` Migration

### What Changes

#### Cargo.toml

Replace:
```toml
deno_core = "0.311"
deno_ast = { version = "0.53", features = ["transpiling"] }
ureq = "2"
getrandom = "0.2"
```

With:
```toml
deno_runtime = "0.XXX"  # version TBD — pins deno_core, deno_ast, etc.
deno_permissions = "0.XXX"
```

`deno_runtime` re-exports `deno_core` and `deno_ast`, so existing Rust code using those types compiles without changes. `ureq` and `getrandom` are no longer needed — `deno_runtime` provides native `fetch` and `crypto`.

#### RuntimeResource & Runtime Creation

Current `runtime_new` manually:
1. Creates `JsRuntime` with `RuntimeOptions`
2. Registers 4 custom extensions (`denox_timer_ext`, `denox_globals_ext`, `denox_fetch_ext`, `denox_callback_ext`)
3. Executes ~2000 lines of inline JS polyfills

New approach:
1. Creates `deno_runtime::worker::MainWorker` with `WorkerOptions`
2. Configures `deno_permissions::PermissionsContainer` from options
3. Registers only `denox_callback_ext` (our custom JS→Elixir bridge)
4. No polyfills needed — `MainWorker` provides all Web APIs, Node compat, `Deno.*` namespace

The `RuntimeResource` struct stays the same (sender channel, callback_rx, pending_callbacks). The V8 thread pattern stays the same. Only the runtime construction changes.

#### MainWorker Integration with Command/Channel Pattern

The current architecture spawns a dedicated `std::thread` per runtime that owns a `JsRuntime` and receives `Command` messages via `mpsc::channel`. `MainWorker` wraps a `JsRuntime` internally, so the integration works as follows:

- **Eval commands:** Use `worker.js_runtime.execute_script()` to access the inner `JsRuntime` directly. This preserves the existing `process_eval` logic.
- **Async/module commands:** Use `worker.execute_main_module()` and `worker.js_runtime.load_side_es_module_from_code()` for module evaluation. `call_function` continues to use `worker.js_runtime.execute_script()`.
- **Event loop:** Use `worker.run_event_loop(false)` which wraps the inner runtime's event loop. This is compatible with our existing `tokio::runtime::Builder::new_current_thread()` pattern — `MainWorker` does not create its own tokio runtime; it uses whichever runtime is active on the current thread.
- **Custom extension:** `denox_callback_ext` is registered via `WorkerOptions::custom_extensions` alongside the built-in extensions.

#### Files to Remove

| File | Reason |
|------|--------|
| `timer_op.rs` | `MainWorker` provides native `setTimeout`/`setInterval` |
| `fetch_op.rs` | `MainWorker` provides native `fetch` |
| `globals_op.rs` | `MainWorker` provides `performance`, `crypto`, `console`, etc. |
| JS polyfills in `lib.rs` (~2000 lines) | All Web APIs provided natively |

#### Files to Keep (Modified)

| File | Changes |
|------|---------|
| `lib.rs` | Replace `JsRuntime` creation with `MainWorker`, remove polyfill injection, keep Command/channel pattern |
| `callback_op.rs` | No changes — still our custom extension |
| `ts_loader.rs` | Simplify — `MainWorker` handles npm/jsr resolution natively. Keep for custom import map support if `MainWorker`'s built-in resolver doesn't cover our import_map API |

#### Permissions

The `sandbox` parameter is replaced by `permissions` in `runtime_new`:
```rust
/// Permissions mode for the runtime.
/// Serialized as JSON from Elixir.
#[derive(Deserialize)]
#[serde(tag = "mode")]
enum PermissionsConfig {
    /// Allow everything. Logs a warning at runtime creation.
    #[serde(rename = "allow_all")]
    AllowAll,
    /// Deny everything (replaces old `sandbox: true`).
    #[serde(rename = "deny_all")]
    DenyAll,
    /// Granular permissions.
    #[serde(rename = "granular")]
    Granular {
        #[serde(flatten)]
        options: PermissionsOptions,
    },
}

fn runtime_new(
    base_dir: String,
    cache_dir: Option<String>,
    import_map_json: Option<String>,
    callback_pid: Option<LocalPid>,
    snapshot: Option<Binary>,
    permissions_json: Option<String>,  // Replaces `sandbox: bool`
) -> Result<ResourceArc<RuntimeResource>, String>
```

The permissions JSON uses an explicit `"mode"` discriminator to avoid `None`/`"none"` ambiguity:

**Allow all** (default when `permissions_json` is `None`):
```json
{"mode": "allow_all"}
```
Logs `[warning] Denox runtime created with allow-all permissions. Use granular permissions in production.` via Erlang logger.

**Deny all** (replaces `sandbox: true`):
```json
{"mode": "deny_all"}
```

**Granular:**
```json
{
  "mode": "granular",
  "allow_net": true,
  "allow_read": ["/tmp", "/data"],
  "allow_env": ["HOME", "PATH"],
  "deny_write": true
}
```

JSON-to-`PermissionsOptions` conversion rules for granular fields:
- `true` → `Some(vec![])` (allow/deny all for that category)
- `false` → `None` (unset, use default)
- `["value1", "value2"]` → `Some(vec!["value1", "value2"])` (granular list)

When `permissions_json` is `None` (no argument passed), defaults to `AllowAll` for backward compatibility.

#### Elixir API Changes

`Denox.runtime/1` gains a `:permissions` option:
```elixir
Denox.runtime(
  permissions: :all,                    # allow everything (default)
  permissions: :none,                   # deny everything (same as sandbox: true)
  permissions: [allow_net: true,        # granular
                allow_read: ["/tmp"],
                deny_env: true]
)
```

The `:sandbox` option is deprecated but still accepted — it maps to `permissions: :none` internally.

#### Backward Compatibility

- All existing Elixir API functions unchanged
- All existing tests should pass (globals, fetch, timers, etc. now provided by `MainWorker` instead of polyfills)
- JS code gains access to `Deno.*` APIs that were previously unavailable
- Only breaking change: sandbox mode now uses Deno's permission system instead of stripping extensions entirely. Behavior should be equivalent but error messages will differ.

#### Snapshot Support

`MainWorker` has its own snapshot mechanism. We need to investigate whether our current `create_snapshot` approach (using `JsRuntimeForSnapshot`) is compatible with `MainWorker` or needs adaptation. This may require using `deno_runtime`'s snapshot creation APIs instead.

**Risk:** Snapshot binary format may differ between `deno_core` and `deno_runtime`. Existing snapshots would be incompatible. This is acceptable since snapshots are ephemeral build artifacts, not persisted across versions.

**Pre-requisite spike:** Before starting Part 1, run a spike to verify:
1. Can `JsRuntimeForSnapshot` create snapshots that load into `MainWorker`?
2. If not, does `deno_runtime` provide an equivalent snapshot creation API?
3. Does the `create_snapshot` Elixir API need signature changes?

If snapshots are incompatible, the `create_snapshot` API will need to change (potentially accepting `WorkerOptions` instead of raw setup code), which cascades into `Denox.runtime/1` and `Denox.Pool`. Identify this early.

#### Cache Directory & `DENO_DIR`

`MainWorker` uses `DENO_DIR` (default: `~/.cache/deno`) for npm cache, compiled modules, and registry cache. Our `:cache_dir` option maps to this:

- If `:cache_dir` is provided, set `DENO_DIR` environment variable before creating the worker, AND pass it via `WorkerOptions::cache_dir` if available
- If `:cache_dir` is `nil`, respect the system `DENO_DIR` if set, otherwise use Deno's default
- The existing per-module disk cache in `ts_loader.rs` becomes redundant — `MainWorker`'s built-in cache handles this

---

## Part 2: `Denox.Run` — NIF-backed Runtime GenServer

### Purpose

Long-lived Deno runtime as a GenServer with bidirectional I/O, backed by an in-process `MainWorker` instead of a subprocess.

### NIF Layer

New NIF functions:

```rust
/// Create a long-lived runtime that loads and runs a module.
/// Returns a RuntimeRunResource with I/O channels.
#[rustler::nif(schedule = "DirtyCpu")]
fn runtime_run(
    specifier: String,
    permissions: Option<String>,
    env: Option<Vec<(String, String)>>,
    args: Option<Vec<String>>,
    cache_dir: Option<String>,
    import_map_json: Option<String>,
) -> Result<ResourceArc<RuntimeRunResource>, String>

/// Send a line to the runtime's stdin channel.
#[rustler::nif]
fn runtime_run_send(
    resource: ResourceArc<RuntimeRunResource>,
    data: String,
) -> Result<(), String>

/// Block on dirty I/O scheduler until a line is available from stdout.
/// Uses DirtyIo (not DirtyCpu) to avoid exhausting the smaller CPU scheduler pool.
#[rustler::nif(schedule = "DirtyIo")]
fn runtime_run_recv(
    resource: ResourceArc<RuntimeRunResource>,
) -> Result<Option<String>, String>

/// Signal the runtime to shut down.
#[rustler::nif]
fn runtime_run_stop(
    resource: ResourceArc<RuntimeRunResource>,
) -> Result<(), String>

/// Check if the runtime is still running.
#[rustler::nif]
fn runtime_run_alive(
    resource: ResourceArc<RuntimeRunResource>,
) -> bool
```

#### RuntimeRunResource

```rust
/// Default stdout buffer size. Provides backpressure when the Elixir
/// side is slower than the JS side. Configurable via `buffer_size` option.
const DEFAULT_BUFFER_SIZE: usize = 1024;

struct RuntimeRunResource {
    stdin_tx: mpsc::Sender<String>,           // unbounded — Elixir controls send rate
    stdout_rx: Mutex<mpsc::Receiver<String>>,  // bounded — backpressure from Elixir
    stop_tx: mpsc::Sender<()>,
    alive: Arc<AtomicBool>,
}
```

The stdout channel uses `mpsc::sync_channel(buffer_size)` (bounded) to apply backpressure when the Elixir consumer falls behind. Default buffer is 1024 lines. Configurable via the `:buffer_size` option in `Denox.Run.start_link/1`. The stdin channel remains unbounded since the Elixir side controls the send rate.

The runtime thread:
1. Creates `MainWorker` with permissions and env
2. Bridges stdin/stdout via OS pipes: creates `pipe()` pairs, passes the write-end FDs to `MainWorker` via `deno_io::Stdio { stdin: StdioPipe::File(write_fd), stdout: StdioPipe::File(read_fd) }`, and spawns threads to bridge between pipe FDs and mpsc channels. This avoids implementing custom `deno_io` internals while providing channel-based I/O to the Elixir side.
3. Resolves the specifier (npm:, jsr:, file path, URL)
4. Loads as main module
5. Pumps the event loop continuously until stop signal or module completion
6. Sets `alive` to false on exit

#### Thread Scaling

Each `Denox.Run` instance spawns **2N+1 OS threads**:
- 1 event loop thread (runs `MainWorker`, pumps V8 event loop)
- 1 pipe reader thread (reads stdout pipe FD → sends to bounded mpsc channel)
- 1 pipe writer thread (receives from stdin mpsc channel → writes to stdin pipe FD)

Plus 1 dirty I/O scheduler thread is occupied per instance while `runtime_run_recv` blocks. With OTP's default of 10 dirty I/O schedulers, this limits concurrent `Denox.Run` instances to ~10 before causing scheduler contention. For higher concurrency, increase via `+SDio N` BEAM flag.

### Elixir GenServer

`Denox.Run` keeps the exact same public API:

```elixir
# Start
{:ok, pid} = Denox.Run.start_link(
  package: "@modelcontextprotocol/server-github",
  permissions: :all,
  env: %{"GITHUB_PERSONAL_ACCESS_TOKEN" => token}
)

# I/O
:ok = Denox.Run.send(pid, data)
{:ok, line} = Denox.Run.recv(pid, timeout: 5000)

# Subscribe
Denox.Run.subscribe(pid)
# => {:denox_run_stdout, pid, line}
# => {:denox_run_exit, pid, status}

# Lifecycle
Denox.Run.alive?(pid)
Denox.Run.stop(pid)
```

#### Internal Changes

| Current (subprocess) | New (NIF) |
|---|---|
| `Port.open({:spawn_executable, deno_path}, ...)` | `Native.runtime_run(specifier, ...)` |
| `Port.command(port, data)` | `Native.runtime_run_send(resource, data)` |
| Port messages `{port, {:data, {:eol, line}}}` | Receiver task calling `Native.runtime_run_recv(resource)` in a loop |
| `Port.close(port)` | `Native.runtime_run_stop(resource)` |
| `{port, {:exit_status, status}}` | `runtime_run_recv` returns `None` (closed) |

The GenServer spawns a `Task` on init that loops `runtime_run_recv` on a dirty scheduler, sending lines back to the GenServer as messages. This preserves the subscriber/waiter dispatch logic unchanged.

#### Specifier Resolution

Same as current `Denox.Run`:
- `"@scope/name"` → `"npm:@scope/name"`
- `"npm:"`, `"jsr:"`, `"http://"`, `"https://"`, `"file://"` prefixed → passthrough
- Everything else → treated as file path

Resolution now happens inside the NIF via `MainWorker`'s built-in module resolver.

#### Environment Variables

`:env` option sets environment variables in the worker's permission scope. JS code accesses via `Deno.env.get()`. Unlike the subprocess approach, these don't affect the BEAM process environment.

**Behavior for disallowed env vars:** When permissions deny access to an env var (e.g. `deny_env: ["SECRET"]`), `Deno.env.get("SECRET")` throws a `Deno.errors.PermissionDenied` error. This matches Deno CLI behavior. It does NOT silently return `undefined` — callers must handle the error or use a try/catch.

#### Telemetry

Events:
- `[:denox, :run, :start]` — `%{package: _, file: _, backend: :nif}`
- `[:denox, :run, :stop]` — `%{package: _, file: _, exit_status: _, backend: :nif}`
- `[:denox, :run, :recv]` — `%{line_bytes: _, backend: :nif}` — emitted on each received line, measurements include `%{system_time: _}`. Useful for I/O throughput observability and MCP debugging.

`exit_status` will be `0` for clean shutdown, `1` for error, matching subprocess convention.

---

## Part 3: `Denox.CLI` — Bundled Deno Binary

### Purpose

Download and manage a platform-specific Deno CLI binary, following the `tailwind`/`esbuild` hex package pattern. Disabled by default. Primary use case: testing.

### Configuration

```elixir
# config/test.exs
config :denox, :cli,
  version: "2.1.4"
```

No config = module not available. The CLI feature is opt-in.

### `Denox.CLI` Module

```elixir
defmodule Denox.CLI do
  @moduledoc """
  Manages a bundled Deno CLI binary.

  Disabled by default. Enable by setting the version in config:

      config :denox, :cli, version: "2.1.4"
  """

  @doc "Path to the cached deno binary. Downloads if needed."
  @spec bin_path() :: {:ok, String.t()} | {:error, term()}
  def bin_path

  @doc "Download the configured deno version for this platform."
  @spec install() :: :ok | {:error, term()}
  def install

  @doc "Check if the binary is already downloaded."
  @spec installed?() :: boolean()
  def installed?

  @doc "The configured deno version, or nil if not configured."
  @spec configured_version() :: String.t() | nil
  def configured_version
end
```

### Platform Detection & Download

| Platform | Architecture | Download URL |
|----------|-------------|-------------|
| macOS | x86_64 | `https://github.com/denoland/deno/releases/download/v{version}/deno-x86_64-apple-darwin.zip` |
| macOS | aarch64 | `https://github.com/denoland/deno/releases/download/v{version}/deno-aarch64-apple-darwin.zip` |
| Linux | x86_64 | `https://github.com/denoland/deno/releases/download/v{version}/deno-x86_64-unknown-linux-gnu.zip` |
| Linux | aarch64 | `https://github.com/denoland/deno/releases/download/v{version}/deno-aarch64-unknown-linux-gnu.zip` |

Binary cached at: `_build/denox_cli-{version}/deno`

### Mix Task

```
mix denox.cli.install    # Download the configured deno binary
```

### `Denox.CLI.Run` Module

The current `Denox.Run` code moves here with one change: `find_deno/0` resolves from `Denox.CLI.bin_path()` instead of `System.find_executable("deno")`.

```elixir
defmodule Denox.CLI.Run do
  @moduledoc """
  Run Deno programs as managed subprocesses using the bundled CLI.

  Same API as `Denox.Run`, but uses the bundled binary from `Denox.CLI`
  instead of the NIF runtime. Primarily useful for testing or when
  full CLI features (deno fmt, deno lint) are needed.
  """

  # Same public API as Denox.Run:
  # start_link/1, send/2, recv/2, subscribe/1, unsubscribe/1,
  # alive?/1, os_pid/1, stop/1
end
```

The implementation is a near-copy of the current `Denox.Run` with `find_deno/0` changed to:

```elixir
defp find_deno do
  case Denox.CLI.bin_path() do
    {:ok, path} -> {:ok, path}
    {:error, _} -> {:error, "Deno CLI not configured. Add `config :denox, :cli, version: \"2.x.x\"` and run `mix denox.cli.install`"}
  end
end
```

### Telemetry

`Denox.CLI.Run` emits the same telemetry events as `Denox.Run`, with `backend: :cli`:
- `[:denox, :run, :start]` — `%{package: _, file: _, backend: :cli}`
- `[:denox, :run, :stop]` — `%{package: _, file: _, exit_status: _, backend: :cli}`
- `[:denox, :run, :recv]` — `%{line_bytes: _, backend: :cli}`

---

## Shared Behaviour: `Denox.Run.Base`

`Denox.Run` and `Denox.CLI.Run` share the same public API and subscriber/waiter dispatch logic. Instead of duplicating ~150 lines, extract a shared behaviour module:

```elixir
defmodule Denox.Run.Base do
  @moduledoc false
  # Shared GenServer dispatch logic for Run modules.

  @callback init_backend(keyword()) :: {:ok, backend_state} | {:error, term()}
  @callback send_backend(backend_state, String.t()) :: :ok | {:error, term()}
  @callback stop_backend(backend_state) :: :ok
end
```

`Denox.Run.Base` provides:
- The `__using__` macro that injects the GenServer boilerplate
- Shared state struct (`subscribers`, `recv_waiters`, `stdout_buffer`)
- `dispatch_line/2`, `drain_waiters/1` — identical in both modules
- `handle_call` for `:recv`, `{:subscribe, _}`, `{:unsubscribe, _}`, `:alive?`
- Telemetry emission with `backend` metadata

Each implementation module (`Denox.Run`, `Denox.CLI.Run`) only implements:
- `init_backend/1` — create NIF resource or open Port
- `send_backend/2` — write to NIF channel or Port
- `stop_backend/1` — stop NIF resource or close Port
- Backend-specific message handling (Port messages vs Task messages)

---

## Implementation Order

1. **Part 3 first (CLI bundle)** — lowest risk, independent of NIF changes. Copy current `Denox.Run` to `Denox.CLI.Run`, build `Denox.CLI` binary manager. This gives us a working test harness.
2. **Part 1 (deno_core → deno_runtime)** — migrate the Rust NIF. All existing eval/call tests validate the migration.
3. **Part 2 (NIF-backed Denox.Run)** — build the new `Denox.Run` on top of the migrated NIF. Use `Denox.CLI.Run` in tests to validate output parity.

---

## Module Summary

| Module | Backend | Use Case |
|--------|---------|----------|
| `Denox` | NIF (`deno_runtime`) | eval/call JS/TS inline code |
| `Denox.Pool` | NIF (`deno_runtime`) | Concurrent eval/call with round-robin |
| `Denox.Run` | NIF (`deno_runtime`) | Long-lived runtime with I/O streaming |
| `Denox.CLI` | Bundled binary | Binary download/management |
| `Denox.CLI.Run` | Subprocess (bundled `deno`) | Subprocess runner for testing |
| `Denox.CallbackHandler` | NIF | JS→Elixir RPC |
| `Denox.Deps` | CLI (system `deno` → `Denox.CLI` fallback → actionable error) | deno.json dependency management |
| `Denox.Npm` | CLI (system `deno` → `Denox.CLI` fallback → actionable error) | npm/jsr bundling |

---

## Files Changed

### Rust (native/denox_nif/)

| File | Action |
|------|--------|
| `Cargo.toml` | Replace `deno_core`/`deno_ast`/`ureq`/`getrandom` with `deno_runtime`/`deno_permissions` |
| `src/lib.rs` | Replace `JsRuntime` with `MainWorker`, remove polyfills, add `runtime_run` NIF functions |
| `src/timer_op.rs` | Delete |
| `src/fetch_op.rs` | Delete |
| `src/globals_op.rs` | Delete |
| `src/callback_op.rs` | Keep unchanged |
| `src/ts_loader.rs` | Simplify or remove (MainWorker handles module loading) |
| `src/runtime_run.rs` | New — `RuntimeRunResource` and NIF functions for long-lived runtime |

### Elixir (lib/denox/)

| File | Action |
|------|--------|
| `lib/denox/native.ex` | Add NIF stubs: `runtime_run`, `runtime_run_send`, `runtime_run_recv`, `runtime_run_stop`, `runtime_run_alive` |
| `lib/denox/run/base.ex` | New — shared behaviour and dispatch logic for Run modules |
| `lib/denox/run.ex` | Rewrite internals to use NIF instead of Port, `use Denox.Run.Base` |
| `lib/denox/cli.ex` | New — binary download/management |
| `lib/denox/cli/run.ex` | New — subprocess runner using bundled CLI, `use Denox.Run.Base` |
| `lib/mix/tasks/denox.cli.install.ex` | New — mix task |
| `lib/denox.ex` | Add `:permissions` option to `runtime/1`, deprecate `:sandbox` |
| `lib/denox/pool.ex` | No changes needed — holds `RuntimeResource` refs which are unchanged |
| `lib/denox/deps.ex` | Update `find_deno/0`: try `System.find_executable("deno")` first, then `Denox.CLI.bin_path()`, then fail with actionable error |
| `lib/denox/npm.ex` | Update `find_deno/0`: same fallback chain as `deps.ex` |

### Tests

| File | Action |
|------|--------|
| `test/denox_run_test.exs` | Update to test NIF-backed `Denox.Run` (remove `:deno` tag) |
| `test/denox_cli_run_test.exs` | New — tests for `Denox.CLI.Run` (tagged `:deno_cli`) |
| `test/denox_cli_test.exs` | New — tests for `Denox.CLI` binary management |
| `test/denox_globals_test.exs` | May need updates if native APIs differ from polyfills |
| All other tests | Should pass unchanged |

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| `deno_runtime` compile time (~30-60 min) | Slower CI, slower local dev | Precompiled NIFs already handle this; local builds already slow |
| Binary size increase | Larger NIF (~50-100MB) | Acceptable — V8 is already the bulk |
| `deno_runtime` version compatibility | API churn between versions | Pin exact version, update deliberately |
| Snapshot format incompatibility | Existing snapshots break | Snapshots are build artifacts, not persisted |
| `MainWorker` stdin/stdout channel bridging | May require custom `Deno.stdin`/`Deno.stdout` implementation | Deno's `WorkerOptions` supports custom I/O via `deno_io` crate |
| `deno_runtime` pulls in more native deps (sqlite, ffi, etc.) | Build complexity | Feature-gate unnecessary crates if possible |
| Import map API compatibility | `MainWorker` may handle import maps differently | Test thoroughly; adapt `ts_loader.rs` if needed |
| Higher per-runtime memory usage | `MainWorker` bootstraps more JS than bare `deno_core` | Document; acceptable for the feature set gained |
| `deno_core` re-export uncertainty | `deno_runtime` may not re-export `deno_core` publicly | Keep `deno_core` as direct dep if needed, version-constrained by `deno_runtime` |
| `ureq` removal depends on `ts_loader.rs` decision | May still be needed if custom module loader is kept | Remove `ureq` only after confirming `MainWorker`'s resolver covers all import map use cases |
| Snapshot compatibility with `MainWorker` | `JsRuntimeForSnapshot` snapshots may not load into `MainWorker` | Spike before Part 1; may need to use `deno_runtime`'s snapshot creation |
| Thread scaling per `Denox.Run` instance | 3 OS threads + 1 dirty I/O scheduler per instance | Document; increase `+SDio N` for high concurrency; consider async recv in future |
| Bounded stdout channel backpressure | JS writes block when buffer full, can stall event loop | Default 1024 lines is generous; make configurable via `:buffer_size` |

---

## Success Criteria

1. All existing tests pass with `deno_runtime` backend
2. `Denox.Run` works without `deno` CLI installed
3. `Denox.CLI.Run` downloads and uses bundled binary
4. JS code can use `Deno.*` APIs (file I/O, net, etc.) when permissions allow
5. Sandbox mode denies all permissions via Deno's native system
6. No JS polyfill code remains in the Rust NIF
