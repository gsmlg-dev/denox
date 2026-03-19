# Denox

[![Hex.pm](https://img.shields.io/hexpm/v/denox.svg)](https://hex.pm/packages/denox)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/denox)
[![CI](https://github.com/gsmlg-dev/denox/actions/workflows/ci.yml/badge.svg)](https://github.com/gsmlg-dev/denox/actions/workflows/ci.yml)
[![Test](https://github.com/gsmlg-dev/denox/actions/workflows/test.yml/badge.svg)](https://github.com/gsmlg-dev/denox/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/hexpm/l/denox.svg)](https://opensource.org/licenses/MIT)

Embed the [Deno](https://deno.land) TypeScript/JavaScript runtime in Elixir via a Rustler NIF.

Denox gives Elixir applications first-class access to the JS/TS ecosystem — evaluate JavaScript, transpile and run TypeScript, load ES modules, import from CDNs, and manage npm/jsr dependencies — all in-process, no external services required.

## Features

- **JavaScript evaluation** — sub-millisecond V8 eval via `deno_core`
- **TypeScript transpilation** — native swc/deno_ast, no type-checking overhead
- **ES module loading** — `import`/`export` between `.ts`/`.js` files
- **Async evaluation** — `await`, dynamic `import()`, Promise resolution
- **CDN imports** — fetch from esm.sh, esm.run, etc. with in-memory + disk caching
- **Dependency management** — `deno.json` + `deno install` for npm/jsr packages
- **Pre-bundling** — `deno bundle` for self-contained JS files
- **Runtime pool** — round-robin across N V8 isolates for concurrent workloads
- **Import maps** — bare specifier resolution via `import_map` option
- **JS → Elixir callbacks** — call Elixir functions from JavaScript
- **V8 snapshots** — pre-initialize global state for faster cold starts
- **Telemetry** — built-in `:telemetry` events for eval timing

## Installation

Add `denox` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:denox, "~> 0.4"}
  ]
end
```

### Build requirements

The first compile takes ~20-30 minutes because V8 compiles from source. Subsequent compiles are fast.

- **Rust** (stable) — install via [rustup](https://rustup.rs)
- **Elixir** 1.17+ / OTP 27+

To force a local build (instead of using precompiled binaries):

```bash
DENOX_BUILD=true mix compile
```

## Quick Start

```elixir
# Create a runtime
{:ok, rt} = Denox.runtime()

# Evaluate JavaScript
{:ok, "3"} = Denox.eval(rt, "1 + 2")

# Evaluate TypeScript (transpiled via swc, no type-checking)
{:ok, "42"} = Denox.eval_ts(rt, "const x: number = 42; x")

# Async evaluation (Promises, dynamic import)
{:ok, "99"} = Denox.eval_async(rt, "return await Promise.resolve(99)")

# Decode JSON results to Elixir terms
{:ok, %{"a" => 1}} = Denox.eval_decode(rt, "({a: 1})")

# Call JavaScript functions
Denox.exec(rt, "globalThis.double = (n) => n * 2")
{:ok, "10"} = Denox.call(rt, "double", [5])

# Load and evaluate files
{:ok, result} = Denox.eval_file(rt, "path/to/script.ts")

# Load ES modules with import/export
{:ok, _} = Denox.eval_module(rt, "path/to/module.ts")
```

## Runtime Pool

For concurrent workloads, use a pool of V8 runtimes:

```elixir
# In your supervision tree
children = [
  {Denox.Pool, name: :js_pool, size: 4}
]

# Use the pool (round-robin across runtimes)
{:ok, result} = Denox.Pool.eval(:js_pool, "1 + 2")
{:ok, result} = Denox.Pool.eval_ts(:js_pool, "const x: number = 42; x")
{:ok, result} = Denox.Pool.eval_async(:js_pool, "return await Promise.resolve(99)")
```

## Deno Subprocess (`Denox.Run`)

Run full Deno programs as managed OTP subprocesses with bidirectional stdio. Ideal for running MCP servers, CLI tools, or any npm/jsr package that needs its own process.

```elixir
# Run an MCP server from npm
{:ok, mcp} = Denox.Run.start_link(
  package: "@modelcontextprotocol/server-github",
  permissions: :all,
  env: %{"GITHUB_PERSONAL_ACCESS_TOKEN" => System.fetch_env!("GITHUB_TOKEN")}
)

# Send JSON-RPC initialize request via stdin
Denox.Run.send(mcp, Jason.encode!(%{
  jsonrpc: "2.0",
  method: "initialize",
  id: 1,
  params: %{
    protocolVersion: "2024-11-05",
    capabilities: %{},
    clientInfo: %{name: "denox", version: "0.4.0"}
  }
}))

# Read the response from stdout
{:ok, response} = Denox.Run.recv(mcp, timeout: 10_000)
%{"result" => %{"capabilities" => capabilities}} = Jason.decode!(response)
```

### Running other MCP servers

```elixir
# Filesystem MCP server
{:ok, fs} = Denox.Run.start_link(
  package: "@modelcontextprotocol/server-filesystem",
  permissions: :all,
  args: ["/path/to/allowed/directory"]
)

# Any npm package that provides a CLI
{:ok, pid} = Denox.Run.start_link(
  package: "cowsay",
  permissions: :all,
  args: ["Hello from Elixir!"]
)
```

### Subscribe to output

```elixir
{:ok, mcp} = Denox.Run.start_link(
  package: "@modelcontextprotocol/server-github",
  permissions: :all,
  env: %{"GITHUB_PERSONAL_ACCESS_TOKEN" => token}
)

# Subscribe to receive all stdout lines as messages
Denox.Run.subscribe(mcp)

# Messages arrive as:
#   {:denox_run_stdout, pid, line}
#   {:denox_run_exit, pid, exit_status}
```

### Supervision

```elixir
# Add to your supervision tree
children = [
  {Denox.Run,
   package: "@modelcontextprotocol/server-github",
   permissions: :all,
   env: %{"GITHUB_PERSONAL_ACCESS_TOKEN" => token},
   name: :github_mcp}
]

Supervisor.start_link(children, strategy: :one_for_one)

# Use the named process
Denox.Run.send(:github_mcp, request)
{:ok, response} = Denox.Run.recv(:github_mcp)
```

## Import Maps

Resolve bare specifiers to file paths or URLs:

```elixir
{:ok, rt} = Denox.runtime(
  base_dir: "/path/to/project",
  import_map: %{
    "utils" => "file:///path/to/project/utils.js",
    "mylib/" => "file:///path/to/project/lib/"
  }
)

# JavaScript can now use bare specifiers
{:ok, _} = Denox.eval_async(rt, """
  const { helper } = await import("utils");
  const { add } = await import("mylib/math.ts");
""")
```

## JS → Elixir Callbacks

Call Elixir functions from JavaScript:

```elixir
# Create a runtime with callbacks
{:ok, rt, handler} = Denox.CallbackHandler.runtime(
  callbacks: %{
    "greet" => fn [name] -> "Hello, #{name}!" end,
    "add" => fn [a, b] -> a + b end,
    "get_user" => fn [id] -> %{id: id, name: "User #{id}"} end
  }
)

# JavaScript calls Elixir functions synchronously
{:ok, result} = Denox.eval(rt, ~s[Denox.callback("greet", "Alice")])
# result => "\"Hello, Alice!\""

{:ok, result} = Denox.eval(rt, ~s[Denox.callback("add", 10, 20)])
# result => "30"
```

## V8 Snapshots

Create V8 snapshots for faster cold starts:

```elixir
# Create a snapshot with pre-initialized state
{:ok, snapshot} = Denox.create_snapshot("""
  globalThis.helper = (x) => x * 2;
  globalThis.config = { debug: false };
""")

# Load the snapshot into a new runtime (instant startup)
{:ok, rt} = Denox.runtime(snapshot: snapshot)
{:ok, "10"} = Denox.call(rt, "helper", [5])

# TypeScript snapshots (transpiled before snapshotting)
{:ok, snapshot} = Denox.create_snapshot(
  "globalThis.add = (a: number, b: number): number => a + b",
  transpile: true
)
```

## CDN Imports

Import directly from CDNs — no tooling required:

```elixir
{:ok, rt} = Denox.runtime(cache_dir: "_denox/cache")

{:ok, result} = Denox.eval_async(rt, """
  const { z } = await import("https://esm.sh/zod@3.22");
  return z.string().parse("hello");
""")
```

## Dependency Management

Manage npm/jsr packages via `deno.json`:

```json
{
  "imports": {
    "zod": "npm:zod@^3.22",
    "lodash": "npm:lodash-es@^4.17",
    "@std/path": "jsr:@std/path@^1.0"
  }
}
```

```bash
# Install dependencies (requires deno CLI)
mix denox.install

# Add/remove dependencies
mix denox.add zod "npm:zod@^3.22"
mix denox.remove zod
```

```elixir
# Create a runtime with installed deps
{:ok, rt} = Denox.Deps.runtime()
```

## Pre-Bundling

Bundle npm packages into self-contained JS files:

```bash
mix denox.bundle npm:zod@3.22 priv/bundles/zod.js
```

```elixir
{:ok, rt} = Denox.runtime()
:ok = Denox.Npm.load(rt, "priv/bundles/zod.js")
```

## Telemetry

Denox emits telemetry events for all eval operations:

| Event | Measurements | Metadata |
|---|---|---|
| `[:denox, :eval, :start]` | `%{system_time: integer}` | `%{type: atom}` |
| `[:denox, :eval, :stop]` | `%{duration: integer}` | `%{type: atom}` |
| `[:denox, :eval, :exception]` | `%{duration: integer}` | `%{type: atom, kind: :error, reason: term}` |

Types: `:eval`, `:eval_ts`, `:eval_async`, `:eval_ts_async`, `:eval_module`, `:eval_file`

## Architecture

- **NIF bridge**: Rustler connects Elixir to Rust
- **V8 isolate**: Each runtime gets a dedicated OS thread (V8 requires LIFO drop ordering)
- **TypeScript**: `deno_ast`/swc transpiles types away without type-checking
- **Module loading**: Custom `ModuleLoader` handles `file://` and `https://` schemes
- **Async**: Event loop pumping for Promises and dynamic imports
- **Safety**: All NIFs run on dirty CPU schedulers; V8 runtimes are Mutex-protected

## License

MIT
