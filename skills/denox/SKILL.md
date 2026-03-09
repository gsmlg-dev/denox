---
name: denox
description: Use when building Elixir applications that need to evaluate JavaScript or TypeScript code, load ES modules, import npm/jsr packages, call JS functions from Elixir, or use V8 snapshots. Triggers on Denox, deno_core, Rustler NIF JS runtime, TypeScript transpilation in Elixir.
---

# Denox — Embed Deno JS/TS Runtime in Elixir

## Overview

Denox embeds a Deno V8 runtime into Elixir via a Rustler NIF. Evaluate JS/TS, load ES modules, import from CDNs/npm/jsr, and call functions across the boundary — all in-process.

## When to Use

- Evaluating JavaScript or TypeScript from Elixir
- Loading ES modules with `import`/`export`
- Using npm/jsr packages in Elixir applications
- Running async JS (Promises, dynamic `import()`)
- Calling Elixir functions from JavaScript (callbacks)
- Pre-initializing V8 state with snapshots

## Quick Reference

### Installation

```elixir
# mix.exs
{:denox, "~> 0.2.0"}
```

Requires Rust (stable). First compile ~20-30 min (V8 builds from source).

### Core API

| Function | Purpose | Event Loop |
|---|---|---|
| `Denox.runtime(opts)` | Create V8 isolate | — |
| `Denox.eval(rt, js)` | Eval JS, return JSON string | No |
| `Denox.eval_ts(rt, ts)` | Transpile+eval TS (no type-check) | No |
| `Denox.eval_async(rt, js)` | Eval with Promises/`import()` | Yes |
| `Denox.eval_ts_async(rt, ts)` | Async TS eval | Yes |
| `Denox.exec(rt, code)` | Eval, discard result (`:ok`) | No |
| `Denox.eval_module(rt, path)` | Load ES module file | Yes |
| `Denox.eval_file(rt, path)` | Read+eval file (no import/export) | No |
| `Denox.call(rt, name, args)` | Call named JS function | No |
| `Denox.call_async(rt, name, args)` | Call async JS function | Yes |
| `Denox.eval_decode(rt, code)` | Eval + `Jason.decode` result | No |
| `Denox.eval_ts_decode(rt, code)` | TS eval + decode | No |
| `Denox.call_decode(rt, name, args)` | Call + decode | No |
| `Denox.call_async_decode(rt, name, args)` | Async call + decode | Yes |

All functions return `{:ok, result} | {:error, message}`. The `exec` variants return `:ok | {:error, message}`.

### Runtime Options

```elixir
Denox.runtime(
  base_dir: "lib/js",           # resolve relative module imports
  sandbox: true,                # disable fs/net extensions
  cache_dir: "_denox/cache",    # disk cache for remote modules
  import_map: %{"utils" => "file:///path/to/utils.js"},
  callback_pid: pid,            # enable JS→Elixir callbacks
  snapshot: snapshot_bytes       # V8 snapshot for fast cold start
)
```

### Sync vs Async

Use `eval`/`call` for simple expressions. Use `eval_async`/`call_async` when code contains:
- `await` or Promises
- Dynamic `import()`
- `setTimeout`/event-loop-dependent code

```elixir
# Sync — fast, no event loop
{:ok, "3"} = Denox.eval(rt, "1 + 2")

# Async — pumps event loop
{:ok, "42"} = Denox.eval_async(rt, "return await Promise.resolve(42)")
```

### TypeScript

Transpile-only via deno_ast/swc. No type-checking (same as `deno run` without `--check`). Type errors like `const x: string = 42` transpile without error.

```elixir
{:ok, "42"} = Denox.eval_ts(rt, "const x: number = 42; x")
```

### Function Calls

Define functions in JS, call from Elixir with JSON-serializable args:

```elixir
Denox.exec(rt, "globalThis.add = (a, b) => a + b")
{:ok, "5"} = Denox.call(rt, "add", [2, 3])
{:ok, 5} = Denox.call_decode(rt, "add", [2, 3])
```

### ES Modules

```elixir
# Load module with import/export support
{:ok, rt} = Denox.runtime(base_dir: "/path/to/project")
{:ok, _} = Denox.eval_module(rt, "/path/to/project/main.ts")
```

### CDN Imports

```elixir
{:ok, rt} = Denox.runtime(cache_dir: "_denox/cache")
{:ok, result} = Denox.eval_async(rt, """
  const { z } = await import("https://esm.sh/zod@3.22");
  return z.string().parse("hello");
""")
```

Must use `eval_async` — dynamic `import()` returns a Promise.

### Runtime Pool

For concurrent workloads (V8 isolates are single-threaded):

```elixir
# Supervision tree
children = [{Denox.Pool, name: :js_pool, size: 4}]

# Usage (round-robin)
{:ok, result} = Denox.Pool.eval(:js_pool, "1 + 2")
Denox.Pool.load_npm(:js_pool, "priv/bundles/zod.js")  # load into all
```

Pool options: `:name` (required), `:size` (default: schedulers count), plus all runtime options.

### JS → Elixir Callbacks

```elixir
{:ok, rt, handler} = Denox.CallbackHandler.runtime(
  callbacks: %{
    "greet" => fn [name] -> "Hello, #{name}!" end,
    "add" => fn [a, b] -> a + b end
  }
)

{:ok, _} = Denox.eval(rt, ~s[Denox.callback("greet", "Alice")])
```

Callback functions receive a list of decoded JSON arguments.

### V8 Snapshots

Pre-initialize global state for instant startup:

```elixir
{:ok, snap} = Denox.create_snapshot("globalThis.helper = (x) => x * 2")
{:ok, rt} = Denox.runtime(snapshot: snap)
{:ok, "10"} = Denox.call(rt, "helper", [5])

# TypeScript snapshots
{:ok, snap} = Denox.create_snapshot("globalThis.add = (a: number, b: number) => a + b", transpile: true)
```

### Dependency Management (`Denox.Deps`)

Requires `deno` CLI at build-time only.

```elixir
# Install from deno.json
Denox.Deps.install()

# Add/remove deps
Denox.Deps.add("zod", "npm:zod@^3.22")
Denox.Deps.remove("zod")

# List deps
{:ok, imports} = Denox.Deps.list()

# Create runtime with installed deps
{:ok, rt} = Denox.Deps.runtime()
```

Mix tasks: `mix denox.install`, `mix denox.add <name> <spec>`, `mix denox.remove <name>`.

### Pre-Bundling (`Denox.Npm`)

Bundle npm packages into self-contained JS files (requires `deno` CLI):

```elixir
Denox.Npm.bundle!("npm:zod@3.22", "priv/bundles/zod.js")
:ok = Denox.Npm.load(rt, "priv/bundles/zod.js")
```

### Telemetry

Events: `[:denox, :eval, :start | :stop | :exception]`
Types: `:eval`, `:eval_ts`, `:eval_async`, `:eval_ts_async`, `:eval_module`, `:eval_file`

## Common Mistakes

| Mistake | Fix |
|---|---|
| Using `eval` with `await`/`import()` | Use `eval_async` — `eval` doesn't pump the event loop |
| Expecting type errors from `eval_ts` | Denox is transpile-only, no type-checking |
| Sharing one runtime across concurrent tasks | Use `Denox.Pool` — V8 isolates are single-threaded |
| Forgetting `return` in `eval_async` | Async wraps code in IIFE; use `return` for the result |
| CDN import without `cache_dir` | Set `cache_dir` to avoid re-fetching on every runtime |
| Running untrusted code without sandbox | Use `sandbox: true` to disable fs/net extensions |
