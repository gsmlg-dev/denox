# Denox — Design Document

## Embed Deno TypeScript/JavaScript Runtime in Elixir

**Version:** 0.5.0
**Status:** Implemented
**Inspired by:** [Pythonx](https://github.com/livebook-dev/pythonx) (embeds CPython in Elixir)
**Prior art:** [DenoRider](https://github.com/aglundahl/deno_rider) (embeds Deno, JS-only eval)

> **Note:** This document reflects the v0.1.0 design. As of v0.5.0, `deno_runtime` (MainWorker)
> replaces `deno_core`, providing full Web API support, native permissions, and the NIF-backed
> `Denox.Run` without requiring an external `deno` binary. See CHANGELOG.md for the full history.

---

## 1. Vision

Denox embeds a TypeScript/JavaScript runtime into the BEAM via a Rustler NIF, giving Elixir applications first-class access to the JS/TS ecosystem without external processes or HTTP bridges.

The key gap Denox fills: DenoRider already embeds Deno's V8 engine for JavaScript evaluation, but lacks TypeScript transpilation, ES module loading, dynamic `import()`, and npm/jsr package resolution — the features that make Deno valuable. Denox adds all of these.

### Goals

- Evaluate JS and TS code in-process with sub-millisecond overhead
- Transparently transpile TypeScript via swc/deno_ast
- Load ES modules from the filesystem with `import`/`export`
- Fetch and cache remote modules from CDNs (esm.sh, esm.run, deno.land/x)
- Manage npm/jsr dependencies via `deno.json` + vendoring (parallel to Pythonx + uv)
- Provide async evaluation for dynamic `import()` and Promise resolution
- Maintain crash isolation — a V8 panic must not take down the BEAM

### Non-Goals

- Type-checking (transpile-only, same as `deno run` without `--check`)
- WebSocket/HTTP server inside the runtime

> **v0.1.0 non-goals now implemented:** The permissions model (granular allow/deny), in-process
> `npm:`/`jsr:` specifier resolution, and long-lived runtime I/O (`Denox.Run`) were added in v0.5.0
> via the `deno_runtime` MainWorker migration.

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│  Elixir Application                                 │
│                                                     │
│  Denox.eval_ts(rt, "const x: number = 42; x")      │
│       │                                             │
│       ▼                                             │
│  ┌─────────────────────────────────────┐            │
│  │ Denox (Elixir API)                  │            │
│  │  - eval / eval_ts / eval_async      │            │
│  │  - call / call_async                │            │
│  │  - eval_module                      │            │
│  │  - JSON marshaling (Jason)          │            │
│  └──────────────┬──────────────────────┘            │
│                 │ Rustler NIF boundary              │
│                 ▼                                    │
│  ┌─────────────────────────────────────┐            │
│  │ denox_nif (Rust)                    │            │
│  │                                     │            │
│  │  RuntimeResource                    │            │
│  │    ├─ Mutex<JsRuntime>              │            │
│  │    └─ tokio::Runtime                │            │
│  │                                     │            │
│  │  TsModuleLoader                     │            │
│  │    ├─ file:// → read + transpile    │            │
│  │    ├─ https:// → fetch + cache      │            │
│  │    └─ transpile via deno_ast/swc    │            │
│  │                                     │            │
│  │  Inline transpiler                  │            │
│  │    └─ deno_ast::parse_module +      │            │
│  │       transpile for eval_ts         │            │
│  └──────────────┬──────────────────────┘            │
│                 │                                    │
│                 ▼                                    │
│  ┌─────────────────────────────────────┐            │
│  │ deno_core (V8 Isolate)              │            │
│  │  - execute_script (sync eval)       │            │
│  │  - load_main_es_module (modules)    │            │
│  │  - run_event_loop (async/promises)  │            │
│  └─────────────────────────────────────┘            │
└─────────────────────────────────────────────────────┘

Dependency Management (build-time only):

┌─────────────────┐     ┌──────────────────┐
│ deno.json        │────▶│ deno CLI          │
│ (import map)     │     │ (install + vendor)│
└─────────────────┘     └────────┬─────────┘
                                 │
                                 ▼
                        ┌──────────────────┐
                        │ _denox/vendor/    │
                        │ (vendored deps)   │
                        │ loaded via file://│
                        └──────────────────┘
```

---

## 3. Rust Crate Dependencies

| Crate | Purpose | Notes |
|---|---|---|
| `deno_core` | V8 isolate, JsRuntime, ModuleLoader trait | Pin version carefully — API churn between releases |
| `deno_ast` | TS→JS transpilation via swc | Enable `transpiling` feature |
| `rustler` | Elixir NIF bindings | `0.35+`, handles ResourceArc, dirty schedulers, term encoding |
| `serde` + `serde_json` | Elixir↔JS data marshaling via JSON | V8 values → serde_v8 → JSON → Elixir binary |
| `tokio` | Async runtime for deno_core event loop | `current_thread` flavor, one per RuntimeResource |
| `url` | URL parsing for module specifiers | Required by deno_core's ModuleSpecifier |

### Version Compatibility

`deno_core` and `deno_ast` versions must be compatible. The Deno monorepo's `Cargo.lock` is the source of truth. As of early 2026, approximate compatible versions:

- `deno_core` ~0.311+ and `deno_ast` ~0.53+ share compatible `v8` crate versions
- `serde_v8` may be re-exported from `deno_core` or need a separate dependency depending on version

**Build time warning:** First compile takes ~20-30 minutes because V8 compiles from source. V8 requires at least `-O1` even in debug profile (add `[profile.dev.package.v8] opt-level = 1` to Cargo.toml).

---

## 4. Core Abstractions

### 4.1 RuntimeResource

The central Rust struct held by Elixir as an opaque reference via Rustler's `ResourceArc`.

```
RuntimeResource
  ├── inner: Mutex<JsRuntime>     // V8 isolate, single-threaded
  └── tokio_rt: tokio::Runtime    // for pumping deno_core's event loop
```

**Why Mutex:** V8 isolates are single-threaded. The BEAM may schedule NIF calls from different dirty schedulers. The Mutex serializes access. This is safe because all NIF functions run on `DirtyCpu` schedulers, so the Mutex never blocks a normal scheduler.

**Why per-resource tokio::Runtime:** `deno_core` requires a tokio runtime for async module loading and event loop operations. Using a shared global tokio runtime would create contention. A per-resource `current_thread` runtime is lightweight and avoids cross-runtime interference.

**Lifecycle:** Created by `runtime_new` NIF, dropped when the Elixir process holding the reference is garbage collected. Rustler's `ResourceArc` handles ref-counting.

### 4.2 TsModuleLoader

Implements `deno_core::ModuleLoader` trait. This is the core extension point that makes Denox different from DenoRider.

**Responsibilities:**

1. **Resolve** — convert import specifiers to absolute URLs via `deno_core::resolve_import`
2. **Load** — fetch source code, determine media type, transpile if TypeScript
3. **Cache** — in-memory HashMap + optional on-disk cache for remote modules

**Dispatch by URL scheme:**

| Scheme | Action |
|---|---|
| `file://` | Read from filesystem, detect MediaType from extension, transpile if TS/TSX/JSX |
| `https://` | HTTP fetch (curl or ureq), detect MediaType from Content-Type header or URL, cache result, transpile if TS |
| `http://` | Same as https (with security warning) |
| Others | Error |

**Transpilation via deno_ast:**

```
source code → deno_ast::parse_module(ParseParams) → parsed.transpile(TranspileOptions, EmitOptions) → JavaScript string
```

Transpile decisions based on `MediaType`:

| MediaType | Action |
|---|---|
| TypeScript, Mts, Cts, Tsx, Jsx, Dts | Transpile to JS |
| JavaScript, Mjs, Cjs | Pass through |
| Json | Pass through as ModuleType::Json |
| Unknown | Default to JS (CDNs serve pre-transpiled) |

**Content-Type to MediaType mapping for remote modules:**

- `application/typescript` → TypeScript (transpile)
- `application/javascript`, `text/javascript` → JavaScript (pass through)
- `application/json` → Json
- Fallback to URL extension-based detection
- CDNs like esm.sh serve pre-transpiled JS, so most remote imports need no transpilation

**Caching strategy:**

- **In-memory:** `Arc<Mutex<HashMap<String, CachedModule>>>` shared within a single TsModuleLoader instance. Lookup before every fetch.
- **On-disk:** Optional. Hash URL to filename (FNV-1a or similar), write to `cache_dir`. Check disk before network. No TTL/expiry — manual invalidation via directory deletion.

**HTTP fetching options (choose one):**

| Approach | Pros | Cons |
|---|---|---|
| Shell out to `curl` | Zero Rust deps, follows redirects | Requires curl, process spawn overhead |
| `ureq` crate | Small (~3 deps), blocking (fits dirty scheduler) | Additional compile time |
| `reqwest` crate | Full-featured, async | ~50 additional crates, heavy |

**Recommendation:** Start with `ureq` (blocking, minimal). The fetch runs on dirty schedulers already, so blocking is fine.

### 4.3 Inline Transpiler

For `eval_ts` — transpiling a TypeScript string (not a file/module):

```
TS string → deno_ast::parse_module with specifier "file:///denox_inline.ts"
          → transpile with SourceMap::None
          → JS string → execute_script
```

This is separate from the ModuleLoader because `execute_script` doesn't go through the module loading pipeline.

---

## 5. NIF Functions

All NIF functions use `schedule = "DirtyCpu"` to avoid blocking BEAM normal schedulers.

### 5.1 runtime_new

```
runtime_new(base_dir: Option<String>, sandbox: bool, cache_dir: Option<String>)
  → {:ok, ResourceArc<RuntimeResource>} | {:error, String}
```

- Creates `TsModuleLoader` with base_dir and optional cache_dir
- Creates `JsRuntime` with the loader as `module_loader`
- If `sandbox`, sets `extensions = vec![]` (no fs/net ops)
- Creates `tokio::Runtime` (current_thread)
- Returns wrapped in `ResourceArc`

### 5.2 eval

```
eval(resource, code: String, transpile: bool)
  → {:ok, json_string} | {:error, message}
```

- If `transpile`, run inline transpiler first
- Call `runtime.execute_script("<denox>", code)` — synchronous, no event loop
- Convert V8 result via `serde_v8::from_v8` → `serde_json::to_string`
- Fallback to `to_rust_string_lossy` if serde_v8 fails (handles non-JSON V8 types)

**Limitation:** Cannot resolve dynamic `import()` or Promises. Use `eval_async` for those.

### 5.3 eval_async

```
eval_async(resource, code: String, transpile: bool)
  → {:ok, json_string} | {:error, message}
```

- Optional transpile step
- Wraps code in async IIFE: `(async () => { <code> })()`
- Calls `execute_script` — returns a Promise (V8 Global)
- Pumps `runtime.run_event_loop(Default::default())` via tokio_rt.block_on
- Inspects `v8::Promise::state()`:
  - `Fulfilled` → extract resolved value via serde_v8
  - `Rejected` → extract error, return `{:error, message}`
  - `Pending` → error (should not happen after event loop drains)

**This is the path for:** dynamic `import()`, `await`, `fetch()`, any Promise-based code.

### 5.4 eval_module

```
eval_module(resource, path: String)
  → {:ok, "undefined"} | {:error, message}
```

- Canonicalize path → `ModuleSpecifier::from_file_path`
- `runtime.load_main_es_module(&specifier).await` — triggers TsModuleLoader for entire import graph
- `runtime.mod_evaluate(mod_id)` — execute module
- `runtime.run_event_loop()` — resolve top-level await
- Returns `{:ok, "undefined"}` on success (modules don't have a "return value")

### 5.5 eval_file

```
eval_file(resource, path: String, transpile: bool)
  → {:ok, json_string} | {:error, message}
```

- Read file to string
- Delegate to `eval` — simpler than eval_module (no import/export support, just script execution)

### 5.6 call_function / call_function_async

```
call_function(resource, func_name: String, args_json: String)
call_function_async(resource, func_name: String, args_json: String)
```

- Build JS expression: `((args) => funcName(...args))(argsJson)`
- Delegate to `eval` or `eval_async` respectively

---

## 6. Elixir API Design

### 6.1 Core Module: Denox

```elixir
# Runtime lifecycle
Denox.runtime(opts \\ [])                    # → {:ok, runtime} | {:error, msg}

# Synchronous eval (no event loop)
Denox.eval(rt, js_code)                      # → {:ok, json} | {:error, msg}
Denox.eval_ts(rt, ts_code)                   # → {:ok, json} | {:error, msg}

# Async eval (pumps event loop — for import(), await, Promises)
Denox.eval_async(rt, js_code)                # → {:ok, json} | {:error, msg}
Denox.eval_ts_async(rt, ts_code)             # → {:ok, json} | {:error, msg}

# Module loading
Denox.eval_module(rt, "path/to/module.ts")   # → :ok | {:error, msg}

# File evaluation
Denox.eval_file(rt, path, opts)              # → {:ok, json} | {:error, msg}

# Execute (ignore return value)
Denox.exec(rt, code)                         # → :ok | {:error, msg}
Denox.exec_ts(rt, code)                      # → :ok | {:error, msg}

# Function calls
Denox.call(rt, "funcName", [arg1, arg2])     # → {:ok, json} | {:error, msg}
Denox.call_async(rt, "asyncFunc", [args])    # → {:ok, json} | {:error, msg}

# Eval + JSON decode to Elixir terms
Denox.eval_decode(rt, code)                  # → {:ok, term} | {:error, msg}
Denox.eval_ts_decode(rt, code)               # → {:ok, term} | {:error, msg}
Denox.call_decode(rt, func, args)            # → {:ok, term} | {:error, msg}
Denox.call_async_decode(rt, func, args)      # → {:ok, term} | {:error, msg}
```

### 6.2 Runtime Options

```elixir
Denox.runtime(
  base_dir: "lib/js",           # base directory for resolving relative module imports
  sandbox: true,                # disable deno_core extensions (no fs/net ops)
  cache_dir: "_denox/cache"     # on-disk cache for remote module fetches
)
```

### 6.3 Denox.Pool

GenServer-based pool of runtimes for concurrent workloads. V8 isolates are single-threaded, so the pool round-robins requests across N runtimes.

```elixir
# Supervision tree
{Denox.Pool, name: :js_pool, size: 4, sandbox: true}

# Usage
Denox.Pool.eval(:js_pool, "1 + 1")
Denox.Pool.eval_ts(:js_pool, "const x: number = 42; x")
Denox.Pool.load_npm(:js_pool, "priv/bundles/zod.js")  # load into all runtimes
```

**Pool implementation:** Simple round-robin with a tuple of runtimes and rotating index. For production, consider NimblePool for checkout-based pooling with backpressure.

### 6.4 Denox.Deps — Dependency Management

Parallel to Pythonx using `uv`. Uses `deno` CLI as the package manager at build-time only.

```
Pythonx workflow:               Denox workflow:
  pyproject.toml                  deno.json
  uv sync                        mix denox.install
  venv/site-packages/             _denox/vendor/
  CPython loads from venv         V8 loads from vendor dir
```

**deno.json format** (Deno's standard import map):

```json
{
  "imports": {
    "zod": "npm:zod@^3.22",
    "lodash": "npm:lodash-es@^4.17",
    "@std/path": "jsr:@std/path@^1.0",
    "oak": "https://deno.land/x/oak@v12/mod.ts"
  }
}
```

**Install process** (`Denox.Deps.install/1` / `mix denox.install`):

1. Read `deno.json` import map
2. Run `deno install --config deno.json` — resolves and caches all dependencies
3. Generate a temporary entrypoint that imports all declared deps
4. Run `deno vendor <entrypoint> --output _denox/vendor/` — copies resolved modules as plain files
5. The vendored directory contains all dependencies as `file://`-loadable modules

**Runtime creation** (`Denox.Deps.runtime/1`):

- Creates a runtime with `base_dir: "_denox/vendor/"` so the TsModuleLoader resolves bare specifiers from the vendored directory
- The vendored import map handles `"zod"` → `./npm/registry.npmjs.org/zod/3.22.0/...`

**Mix tasks:**

```bash
mix denox.install              # vendor all deps from deno.json
mix denox.add zod npm:zod@^3.22     # add dep + reinstall
mix denox.remove lodash              # remove dep + reinstall
```

**Why not resolve npm in-process?**

Deno's `npm:` resolution is implemented in `deno_resolver`, `deno_npm`, and `deno_node` crates, which are tightly coupled to the Deno CLI. They assume access to the npm registry, a global cache, and complex CJS↔ESM interop. Extracting these as embeddable libraries would require maintaining a Deno fork. The `deno vendor` approach delegates this complexity to the CLI at build-time, keeping the runtime NIF simple.

### 6.5 Denox.Npm — Pre-Bundling (Alternative to Vendoring)

For packages that don't vendor cleanly, bundle into a self-contained IIFE JS file.

```elixir
Denox.Npm.bundle!("npm:zod@3.22", "priv/bundles/zod.js")

{:ok, rt} = Denox.runtime()
Denox.Npm.load(rt, "priv/bundles/zod.js")
```

Uses `deno` CLI + esbuild to produce a single file with all dependencies inlined. The bundled file assigns the module to `globalThis.<PackageName>`.

### 6.6 CDN Imports (Zero-Install)

For quick prototyping, import directly from CDNs. No tooling required.

```elixir
{:ok, rt} = Denox.runtime(cache_dir: "_denox/cache")

{:ok, result} = Denox.eval_async(rt, """
  const { z } = await import("https://esm.sh/zod@3.22");
  const schema = z.object({ name: z.string() });
  JSON.stringify(schema.parse({ name: "hello" }))
""")
```

Must use `eval_async` because dynamic `import()` returns a Promise.

---

## 7. Data Flow: eval vs eval_async vs eval_module

### eval (synchronous)

```
Elixir string → [optional TS transpile] → runtime.execute_script()
  → v8::Global<Value> → serde_v8::from_v8 → JSON string → Elixir binary
```

No event loop. No module resolution. Fastest path.

### eval_async (async — Promises, dynamic import)

```
Elixir string → [optional TS transpile] → wrap in async IIFE
  → runtime.execute_script() → v8::Global<Value> (Promise)
  → runtime.run_event_loop() → Promise settles
  → inspect Promise state → extract resolved value
  → serde_v8 → JSON string → Elixir binary
```

Event loop pumped. Dynamic imports resolved via TsModuleLoader. Promises awaited.

### eval_module (ES module file)

```
file path → canonicalize → ModuleSpecifier
  → runtime.load_main_es_module() → TsModuleLoader traverses import graph
    → each file: read → detect type → transpile if TS → ModuleSource
  → runtime.mod_evaluate() → execute module
  → runtime.run_event_loop() → resolve top-level await
  → :ok
```

Full module semantics. Import/export. Top-level await. The TsModuleLoader is called for every module in the dependency graph.

---

## 8. Dependency Strategy — Three Tiers

| Tier | Mechanism | Tooling Required | Best For |
|---|---|---|---|
| **CDN** | `import("https://esm.sh/pkg")` | None | Quick prototyping, small scripts |
| **Vendored** | `deno.json` → `mix denox.install` → `Denox.Deps.runtime()` | `deno` CLI | Production apps, reproducible builds |
| **Bundled** | `mix denox.bundle` → single IIFE file | `deno` CLI | Legacy packages, complex deps |

### Comparison with Pythonx + uv

| Aspect | Pythonx + uv | Denox + deno |
|---|---|---|
| Package registry | PyPI | npm + jsr + HTTPS URLs |
| Dependency file | pyproject.toml | deno.json |
| Install command | `uv sync` | `mix denox.install` (wraps `deno vendor`) |
| Local storage | venv/site-packages/ | _denox/vendor/ |
| Lock file | uv.lock | deno.lock |
| Runtime loads from | venv path | vendor directory (file://) |
| Zero-install option | ❌ | ✅ CDN imports |
| Add dependency | `uv add requests` | `mix denox.add zod npm:zod@^3.22` |
| CLI required at runtime | No (uv is build-time) | No (deno is build-time) |

---

## 9. Thread Safety and Scheduler Model

### BEAM Scheduler Interaction

```
Normal Schedulers (N)     Dirty CPU Schedulers (DirtyCpu)
  │                         │
  │ Elixir code             │ All Denox NIF calls
  │ message passing         │ V8 eval, transpilation
  │ lightweight             │ potentially long-running
  │                         │
  │                         ├── runtime_new
  │                         ├── eval / eval_ts
  │                         ├── eval_async
  │                         ├── eval_module
  │                         └── call_function
```

Every NIF is `schedule = "DirtyCpu"`. This means:

- Normal schedulers are never blocked
- V8 execution runs alongside other dirty work
- The BEAM can preempt other Elixir processes normally

### Mutex on JsRuntime

V8 isolates are single-threaded. Multiple BEAM processes calling `Denox.eval(same_runtime, ...)` concurrently will serialize at the Mutex. This is correct but means:

- One runtime = one concurrent eval at a time
- Use `Denox.Pool` for parallelism (N runtimes = N concurrent evals)
- Pool size should match expected concurrency, not CPU cores

### Tokio Runtime

Each `RuntimeResource` owns a `tokio::Runtime` (current_thread flavor). This is used exclusively for:

- `runtime.run_event_loop()` in eval_async
- `runtime.load_main_es_module()` in eval_module

The tokio runtime is cheap (current_thread = no worker threads) and scoped to the RuntimeResource lifetime.

---

## 10. Error Handling

### V8 Errors

`execute_script` returns `Result<v8::Global<v8::Value>, deno_core::error::JsError>`. JsError contains the JS stack trace. Propagate as `{:error, message}` to Elixir.

### Transpilation Errors

`deno_ast::parse_module` returns parse errors (swc parse failures). These indicate syntax errors in the TypeScript source. Propagate as `{:error, "Transpile error: ..."}`.

Note: swc is a *transpiler*, not a *type-checker*. It strips type annotations without verifying correctness. `const x: string = 42` will transpile to `const x = 42` without error. This matches `deno run` behavior (no type-checking by default).

### Network Errors (Remote Module Fetch)

HTTP fetch failures in TsModuleLoader propagate as module load errors, which surface as `{:error, message}` from eval_async or eval_module.

### Mutex Poisoning

If a panic occurs inside a Mutex lock (e.g., V8 segfault caught by Rust's panic handler), the Mutex becomes poisoned. Subsequent calls return `{:error, "Lock poisoned: ..."}`. The runtime is unrecoverable — Elixir should drop the reference and create a new one.

### Crash Isolation

A V8 crash (segfault in V8 native code) will crash the entire BEAM process. This is inherent to in-process NIF embedding. Mitigations:

- Use sandbox mode (no fs/net extensions) to reduce V8 attack surface
- Don't run untrusted code without careful consideration
- For untrusted code, consider a port/sidecar architecture instead

---

## 11. Implementation Plan

### Phase 1: Minimal JS Eval (DenoRider parity)

1. Scaffold Mix project with Rustler
2. Implement `runtime_new` — create JsRuntime with default RuntimeOptions
3. Implement `eval` — execute_script + serde_v8 result conversion
4. Implement `call_function` — build JS expression, delegate to eval
5. Elixir API: `Denox.runtime/1`, `Denox.eval/2`, `Denox.call/3`
6. Tests: arithmetic, strings, objects, errors, runtime isolation

**Milestone:** `{:ok, "3"} = Denox.eval(rt, "1 + 2")` works.

### Phase 2: TypeScript Transpilation

1. Add `deno_ast` dependency with `transpiling` feature
2. Implement `transpile_inline` function using deno_ast
3. Add `transpile` boolean parameter to `eval` NIF
4. Elixir API: `Denox.eval_ts/2`, `Denox.exec_ts/2`
5. Tests: typed expressions, interfaces, generics, enums, parse errors

**Milestone:** TypeScript with interfaces and generics evaluates correctly.

### Phase 3: ES Module Loading

1. Implement `TsModuleLoader` — `file://` only initially
2. Wire loader into RuntimeOptions.module_loader
3. Implement `eval_module` NIF — load_main_es_module + mod_evaluate + run_event_loop
4. Elixir API: `Denox.eval_module/2`
5. Tests: import/export between .ts files, top-level await

**Milestone:** `import { add } from "./math.ts"` resolves and evaluates.

### Phase 4: Async Evaluation

1. Implement `eval_async` NIF — async IIFE wrapper + event loop pump + Promise inspection
2. Implement `call_function_async` NIF
3. Elixir API: `Denox.eval_async/2`, `Denox.eval_ts_async/2`, `Denox.call_async/3`
4. Tests: Promise resolution/rejection, chained promises, dynamic import

**Milestone:** `await import("./module.ts")` resolves correctly.

### Phase 5: Remote Module Fetching (CDN)

1. Extend TsModuleLoader to handle `https://` scheme
2. Implement HTTP fetching (ureq or curl)
3. Implement in-memory cache (Arc<Mutex<HashMap>>)
4. Implement optional on-disk cache
5. Content-Type and URL-based MediaType detection
6. Add `cache_dir` option to runtime_new
7. Tests: esm.sh import, caching behavior (tag :cdn for optional network tests)

**Milestone:** `await import("https://esm.sh/zod@3.22")` works with caching.

### Phase 6: Dependency Management

1. Implement `Denox.Deps` module — wraps deno CLI for install/vendor
2. Implement `Denox.Deps.install/1` — deno install + deno vendor
3. Implement `Denox.Deps.runtime/1` — creates runtime with vendored base_dir
4. Implement `Denox.Deps.add/2`, `Denox.Deps.remove/2`, `Denox.Deps.list/1`
5. Mix tasks: `mix denox.install`, `mix denox.add`, `mix denox.remove`
6. Tests: full workflow — declare deps, install, use in runtime

**Milestone:** `mix denox.install` vendors npm packages, `Denox.Deps.runtime()` loads them.

### Phase 7: Pool and Production Hardening

1. Implement `Denox.Pool` GenServer with round-robin
2. Add `load_npm` to load bundles into all pool runtimes
3. Consider NimblePool for checkout-based pooling
4. RustlerPrecompiled setup for binary distribution
5. Benchmarks: eval latency, transpile overhead, pool throughput
6. CI: GitHub Actions with Rust + Elixir matrix

### Phase 8: Nice-to-Haves (Post-MVP)

- JS → Elixir callbacks (like DenoRider's `DenoRider.apply`) ✅
- Import map support in eval_async (not just eval_module) ✅
- `Denox.Npm.bundle` for pre-bundling alternative ✅
- Warm-up / snapshot support (V8 snapshots for faster cold start) ✅
- Telemetry integration for eval timing ✅

---

## 12. Project Structure

```
denox/
├── mix.exs
├── deno.json.example
├── CLAUDE.md
├── README.md
├── .formatter.exs
├── .gitignore
│
├── lib/
│   ├── denox.ex                    # Main public API
│   ├── denox/
│   │   ├── native.ex               # Rustler NIF binding stubs
│   │   ├── pool.ex                 # GenServer runtime pool
│   │   ├── deps.ex                 # Dependency management (deno CLI wrapper)
│   │   └── npm.ex                  # Pre-bundling support
│   └── mix/
│       └── tasks/
│           ├── denox.install.ex    # mix denox.install / add / remove
│           └── denox.bundle.ex     # mix denox.bundle
│
├── native/
│   └── denox_nif/
│       ├── Cargo.toml
│       └── src/
│           ├── lib.rs              # NIF entry point, RuntimeResource, all NIF functions
│           └── ts_loader.rs        # TsModuleLoader implementation
│
└── test/
    ├── test_helper.exs
    ├── denox_test.exs              # Core eval/call tests
    ├── denox_ts_test.exs           # TypeScript-specific tests
    ├── denox_module_test.exs       # ES module loading tests
    ├── denox_async_test.exs        # Async eval / Promise tests
    ├── denox_cdn_test.exs          # CDN import tests (@tag :cdn)
    └── denox_deps_test.exs         # Dependency management tests (@tag :deno)
```

---

## 13. Testing Strategy

### Unit Tests (no network, no deno CLI)

- JS eval: arithmetic, strings, objects, arrays, errors
- TS transpilation: typed expressions, interfaces, generics, enums, decorators
- Runtime isolation: separate runtimes don't share state
- State persistence: globalThis modifications persist across evals
- Error handling: syntax errors, runtime errors, type annotation edge cases

### Integration Tests

- ES module loading: import/export between .ts/.js files
- Dynamic import: `await import("./mod.ts")` resolution
- Async evaluation: Promise resolution, rejection, chaining

### Network Tests (tagged `@tag :cdn`)

- CDN imports from esm.sh, esm.run
- Caching: first fetch hits network, second hits cache
- Error handling: invalid URLs, 404s, timeouts

### CLI Tests (tagged `@tag :deno`, require deno binary)

- `Denox.Deps.install` with a test deno.json
- `Denox.Deps.add` / `remove`
- Full workflow: install → runtime → eval with vendored deps

---

## 14. Known Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| `deno_core` API churn between versions | Build failures | Pin exact versions, test upgrades in CI, follow Deno release notes |
| V8 first-build time (~30 min) | Developer friction | RustlerPrecompiled for prebuilt binaries, CI caching |
| V8 crash takes down BEAM | Process loss | Sandbox mode, don't run untrusted code in-process |
| Mutex contention under high load | Latency spikes | Pool with appropriate size, NimblePool for backpressure |
| `deno vendor` may not vendor all npm packages cleanly | Missing deps at runtime | Fallback to Denox.Npm.bundle for problematic packages |
| curl dependency for HTTP fetch | Portability | Replace with ureq crate (blocking, minimal deps) |
| serde_v8 fails on complex V8 types | Incorrect results | Fallback to string conversion, document limitations |

---

## 15. Comparison Matrix

| Feature | Denox | DenoRider | Pythonx |
|---|---|---|---|
| Language runtime | Deno (V8) | Deno (V8) | CPython |
| NIF bridge | Rustler (Rust) | Rustler (Rust) | Erlang NIF (C) |
| TypeScript | ✅ (deno_ast/swc) | ❌ | N/A |
| ES Modules | ✅ | ❌ | N/A |
| Dynamic import() | ✅ (eval_async) | ❌ | N/A |
| CDN imports | ✅ | ❌ | ❌ |
| Package manager | deno CLI (build-time) | ❌ | uv (build-time) |
| Dep vendoring | ✅ (deno vendor) | ❌ | ✅ (venv) |
| Runtime → Elixir callback | ✅ | ✅ | ✅ |
| Import maps | ✅ | ❌ | N/A |
| Precompiled binaries | ❌ (planned) | ✅ | ✅ |
| Sandbox mode | ✅ | ❌ | ❌ |
| Runtime pooling | ✅ | ❌ (single supervised) | ❌ |
