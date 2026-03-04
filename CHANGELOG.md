# Changelog

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
