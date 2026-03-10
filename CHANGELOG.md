# Changelog

## v0.3.1 (unreleased)

### Features

- **Real `setTimeout`** — native `op_sleep` async op for millisecond-accurate delays in `setTimeout`/`setInterval`
- **Convenience functions** — added `eval_async_decode`, `eval_ts_async_decode`, `eval_file_async`, `eval_file_decode`, `eval_file_async_decode` for cleaner API
- **Non-blocking LiveView** — example app uses `Task.start` + `handle_info` for async eval to avoid blocking LiveView during long operations

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
