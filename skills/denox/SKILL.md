---
name: denox
description: Use when building Elixir applications that need to evaluate JavaScript or TypeScript code, run Deno programs as subprocesses (MCP servers, CLI tools), load ES modules, import npm/jsr packages, call JS functions from Elixir, or use V8 snapshots. Also use when the user mentions Denox, deno_core, Rustler NIF JS runtime, TypeScript transpilation in Elixir, running MCP servers from Elixir, or managing Deno subprocesses with OTP supervision. Make sure to trigger this skill even if the user just says "add JS evaluation" or "run a TypeScript server" in an Elixir project that has denox as a dependency.
---

# Denox — Embed Deno JS/TS Runtime in Elixir

## Overview

Denox embeds a Deno V8 runtime into Elixir via a Rustler NIF. Evaluate JS/TS, load ES modules, import from CDNs/npm/jsr, call functions across the boundary, and run full Deno programs as OTP-supervised subprocesses — all from Elixir.

Two modes of operation:
1. **In-process eval** — sub-millisecond V8 eval via NIF (`Denox.eval`, `Denox.call`, etc.)
2. **Subprocess runner** — managed `deno run` process with bidirectional stdio (`Denox.Run`)

## Installation

```elixir
# mix.exs
{:denox, "~> 0.4.0"}
```

Precompiled NIFs available for macOS and Linux (x86_64, aarch64). Local build requires Rust (stable); first compile ~20-30 min (V8 builds from source). Force local build with `DENOX_BUILD=true mix compile`.

Optional JSON config (Elixir 1.18+ has built-in JSON):
```elixir
config :denox, :json_module, Jason  # default is JSON
```

## Core API

### Runtime Creation

```elixir
{:ok, rt} = Denox.runtime(
  base_dir: "lib/js",           # resolve relative module imports
  sandbox: true,                # disable fs/net extensions
  cache_dir: "_denox/cache",    # disk cache for remote modules
  import_map: %{"utils" => "file:///path/to/utils.js"},
  callback_pid: pid,            # enable JS->Elixir callbacks
  snapshot: snapshot_bytes       # V8 snapshot for fast cold start
)
```

### Evaluation Functions

| Function | Purpose | Event Loop | Returns |
|---|---|---|---|
| `Denox.eval(rt, js)` | Eval JS | No | `{:ok, json_string} \| {:error, msg}` |
| `Denox.eval_ts(rt, ts)` | Transpile+eval TS | No | `{:ok, json_string} \| {:error, msg}` |
| `Denox.eval_async(rt, js)` | Eval with await/import() | Yes | `Task.t()` |
| `Denox.eval_ts_async(rt, ts)` | Async TS eval | Yes | `Task.t()` |
| `Denox.exec(rt, code)` | Eval, discard result | No | `:ok \| {:error, msg}` |
| `Denox.exec_ts(rt, code)` | TS eval, discard result | No | `:ok \| {:error, msg}` |
| `Denox.eval_module(rt, path)` | Load ES module (import/export) | Yes | `{:ok, _} \| {:error, msg}` |
| `Denox.eval_file(rt, path, opts)` | Read+eval file | No | `{:ok, json_string} \| {:error, msg}` |
| `Denox.eval_file_async(rt, path, opts)` | Read+eval file async | Yes | `Task.t()` |
| `Denox.call(rt, name, args)` | Call named JS function | No | `{:ok, json_string} \| {:error, msg}` |
| `Denox.call_async(rt, name, args)` | Call async JS function | Yes | `Task.t()` |

**Decode variants** (parse JSON result into Elixir terms):
`eval_decode`, `eval_ts_decode`, `eval_async_decode`, `eval_ts_async_decode`, `eval_file_decode`, `eval_file_async_decode`, `call_decode`, `call_async_decode`

**Await helper** for async functions:
```elixir
task = Denox.eval_async(rt, "return await Promise.resolve(42)")
{:ok, "42"} = Denox.await(task)        # default 5s timeout
{:ok, "42"} = Denox.await(task, 10_000) # custom timeout
```

### Sync vs Async

Use `eval`/`call` for simple expressions. Use `eval_async`/`call_async` when code contains:
- `await` or Promises
- Dynamic `import()`
- `setTimeout`/`setInterval` or event-loop-dependent code

```elixir
# Sync — fast, no event loop
{:ok, "3"} = Denox.eval(rt, "1 + 2")

# Async — pumps event loop, code wrapped in async IIFE
# Use `return` to get the result back
{:ok, "42"} = Denox.eval_async(rt, "return await Promise.resolve(42)") |> Denox.await()
```

### TypeScript

Transpile-only via deno_ast/swc — no type-checking (same as `deno run` without `--check`). Type errors like `const x: string = 42` transpile without error.

```elixir
{:ok, "42"} = Denox.eval_ts(rt, "const x: number = 42; x")
```

Files with `.ts`, `.tsx`, `.mts`, `.cts` extensions are auto-transpiled by `eval_file`.

### Function Calls

Define functions in JS, call from Elixir with JSON-serializable args:

```elixir
Denox.exec(rt, "globalThis.add = (a, b) => a + b")
{:ok, "5"} = Denox.call(rt, "add", [2, 3])
{:ok, 5} = Denox.call_decode(rt, "add", [2, 3])
```

### ES Modules

```elixir
{:ok, rt} = Denox.runtime(base_dir: "/path/to/project")
{:ok, _} = Denox.eval_module(rt, "/path/to/project/main.ts")
```

### CDN Imports

```elixir
{:ok, rt} = Denox.runtime(cache_dir: "_denox/cache")
{:ok, result} = Denox.eval_async(rt, """
  const { z } = await import("https://esm.sh/zod@3.22");
  return z.string().parse("hello");
""") |> Denox.await()
```

Must use `eval_async` — dynamic `import()` returns a Promise.

### Import Maps

```elixir
{:ok, rt} = Denox.runtime(
  import_map: %{
    "lodash" => "https://esm.sh/lodash-es@4.17.21",
    "lodash/" => "https://esm.sh/lodash-es@4.17.21/"
  }
)

{:ok, result} = Denox.eval_async(rt, """
  const { default: add } = await import("lodash/add");
  return add(10, 32);
""") |> Denox.await()
```

### Runtime Pool

V8 isolates are single-threaded — one runtime handles one eval at a time. Use `Denox.Pool` for concurrent workloads:

```elixir
# Supervision tree
children = [{Denox.Pool, name: :js_pool, size: 4}]

# Usage (round-robin across runtimes)
{:ok, result} = Denox.Pool.eval(:js_pool, "1 + 2")
Denox.Pool.load_npm(:js_pool, "priv/bundles/zod.js")  # loads into ALL runtimes
```

Pool options: `:name` (required), `:size` (default: `System.schedulers_online()`), plus all runtime options.

### JS -> Elixir Callbacks

```elixir
{:ok, rt, _handler} = Denox.CallbackHandler.runtime(
  callbacks: %{
    "greet" => fn [name] -> "Hello, #{name}!" end,
    "add" => fn [a, b] -> a + b end
  }
)

{:ok, _} = Denox.eval(rt, ~s[Denox.callback("greet", "Alice")])
```

Callback functions receive a list of decoded JSON arguments. Calls are synchronous — JS blocks until Elixir returns.

### V8 Snapshots

Pre-initialize global state for instant startup:

```elixir
{:ok, snap} = Denox.create_snapshot("globalThis.helper = (x) => x * 2")
{:ok, rt} = Denox.runtime(snapshot: snap)
{:ok, "10"} = Denox.call(rt, "helper", [5])

# TypeScript snapshots
{:ok, snap} = Denox.create_snapshot(
  "globalThis.add = (a: number, b: number) => a + b",
  transpile: true
)
```

## Denox.Run — Managed Deno Subprocesses

Run full Deno programs (MCP servers, CLI tools, scripts) as OTP-supervised subprocesses with bidirectional stdio.

### Starting a Subprocess

```elixir
# Run an npm package
{:ok, pid} = Denox.Run.start_link(
  package: "@modelcontextprotocol/server-github",
  permissions: :all,
  env: %{"GITHUB_PERSONAL_ACCESS_TOKEN" => token}
)

# Run a local file
{:ok, pid} = Denox.Run.start_link(
  file: "scripts/server.ts",
  permissions: [allow_net: true, allow_env: ["API_KEY"]],
  args: ["--port", "3000"]
)
```

Options:
- `:package` or `:file` — what to run (one required)
- `:permissions` — `:all` for `-A`, or keyword list
- `:env` — map of environment variables
- `:args` — extra arguments after the specifier
- `:deno_flags` — extra flags before the specifier
- `:name` — GenServer registration name

Bare `@scope/name` specifiers are automatically prefixed with `npm:`.

### Permission Mapping

```elixir
# Full permissions
permissions: :all  # → deno run -A

# Granular permissions
permissions: [
  allow_net: true,                    # → --allow-net
  allow_net: ["api.github.com"],      # → --allow-net=api.github.com
  allow_env: ["TOKEN", "API_KEY"],    # → --allow-env=TOKEN,API_KEY
  allow_read: ["/data"],              # → --allow-read=/data
  allow_write: ["/tmp"],              # → --allow-write=/tmp
  allow_run: true,                    # → --allow-run
  allow_ffi: true,                    # → --allow-ffi
  allow_sys: true,                    # → --allow-sys
  allow_hrtime: true                  # → --allow-hrtime
]
```

### Communicating via stdio

**Request-response (blocking):**
```elixir
:ok = Denox.Run.send(pid, ~s|{"jsonrpc":"2.0","id":1,"method":"initialize"}|)
{:ok, response} = Denox.Run.recv(pid, timeout: 5000)
```

**Pub/sub (message-based):**
```elixir
Denox.Run.subscribe(pid)

receive do
  {:denox_run_stdout, ^pid, line} -> IO.puts("Output: #{line}")
  {:denox_run_exit, ^pid, status} -> IO.puts("Exited: #{status}")
end

Denox.Run.unsubscribe(pid)
```

### Lifecycle

```elixir
Denox.Run.alive?(pid)                    # → true | false
{:ok, os_pid} = Denox.Run.os_pid(pid)    # → OS process ID
Denox.Run.stop(pid)                       # graceful shutdown
```

### MCP Server Example

```elixir
{:ok, pid} = Denox.Run.start_link(
  package: "@modelcontextprotocol/server-github",
  permissions: :all,
  env: %{"GITHUB_PERSONAL_ACCESS_TOKEN" => System.get_env("GITHUB_TOKEN")}
)

# Initialize the MCP server
init = Jason.encode!(%{
  jsonrpc: "2.0", id: 1, method: "initialize",
  params: %{
    protocolVersion: "2024-11-05",
    capabilities: %{},
    clientInfo: %{name: "my-app", version: "1.0"}
  }
})

:ok = Denox.Run.send(pid, init)
{:ok, response} = Denox.Run.recv(pid, timeout: 5000)
# → {"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},...}}
```

### Supervision

```elixir
children = [
  {Denox.Run,
    name: :mcp_github,
    package: "@modelcontextprotocol/server-github",
    permissions: :all,
    env: %{"GITHUB_PERSONAL_ACCESS_TOKEN" => token}}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

## Dependency Management

### Denox.Deps (vendored via deno.json)

Requires `deno` CLI at build-time only.

```elixir
# Install from deno.json
Denox.Deps.install()

# Add/remove deps
Denox.Deps.add("zod", "npm:zod@^3.22")
Denox.Deps.remove("zod")

# Create runtime with installed deps
{:ok, rt} = Denox.Deps.runtime()
```

Mix tasks: `mix denox.install`, `mix denox.add <name> <spec>`, `mix denox.remove <name>`.

### Denox.Npm (pre-bundling)

Bundle npm packages into self-contained JS files:

```elixir
Denox.Npm.bundle!("npm:zod@3.22", "priv/bundles/zod.js")
:ok = Denox.Npm.load(rt, "priv/bundles/zod.js")
```

Mix task: `mix denox.bundle npm:zod@3.22 priv/bundles/zod.js [--minify]`

## Mix Tasks

| Task | Purpose |
|---|---|
| `mix denox.install` | Install deps from deno.json |
| `mix denox.add <name> <spec>` | Add dependency |
| `mix denox.remove <name>` | Remove dependency |
| `mix denox.bundle <spec> <out>` | Bundle package to JS file |
| `mix denox.run [flags] <specifier>` | Run Deno program with stdio forwarding |

### mix denox.run

Drop-in replacement for `deno run` with stdin/stdout forwarding:

```bash
mix denox.run -A @modelcontextprotocol/server-github
mix denox.run --allow-net --allow-env=GITHUB_TOKEN npm:some-tool
mix denox.run -A scripts/server.ts -- --port 3000
```

## Telemetry

Events emitted via `:telemetry`:

| Event | Measurements | Metadata |
|---|---|---|
| `[:denox, :eval, :start]` | `system_time` | `type` |
| `[:denox, :eval, :stop]` | `duration` | `type` |
| `[:denox, :eval, :exception]` | `duration` | `type, kind, reason` |
| `[:denox, :run, :start]` | `system_time` | `package, file` |
| `[:denox, :run, :stop]` | `system_time` | `package, file, exit_status` |

Eval types: `:eval`, `:eval_ts`, `:eval_async`, `:eval_ts_async`, `:eval_module`, `:eval_file`, `:call`

## Common Mistakes

| Mistake | Fix |
|---|---|
| Using `eval` with `await`/`import()` | Use `eval_async` — `eval` doesn't pump the event loop |
| Expecting type errors from `eval_ts` | Denox is transpile-only, no type-checking |
| Sharing one runtime across concurrent tasks | Use `Denox.Pool` — V8 isolates are single-threaded |
| Forgetting `return` in `eval_async` | Async wraps code in IIFE; use `return` for the result |
| CDN import without `cache_dir` | Set `cache_dir` to avoid re-fetching on every runtime |
| Running untrusted code without sandbox | Use `sandbox: true` to disable fs/net extensions |
| Using bare `@scope/pkg` with `Denox.eval_async` | CDN imports need full URL; bare specifiers need `Denox.Run` or import maps |
