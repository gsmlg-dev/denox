# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Denox embeds the Deno TypeScript/JavaScript runtime in Elixir via a Rustler NIF. It uses deno_core (V8) and deno_ast for transpilation on the Rust side, exposed to Elixir through Rustler.

## Build & Development

Requires Elixir 1.18+, OTP 27+. Uses devenv (Nix) for development environment (`devenv shell`).

```bash
mix deps.get && mix compile          # Compile (uses precompiled NIFs by default)
DENOX_BUILD=true mix compile         # Force local Rust build (~20-30 min, needs Rust toolchain)
```

## Testing

devenv sets `MIX_ENV=dev`, so tests require override:

```bash
MIX_ENV=test mix test                         # All tests
MIX_ENV=test mix test test/denox_test.exs     # Single file
MIX_ENV=test mix test test/denox_test.exs:42  # Single test by line
test-all                                       # devenv shortcut
test-watch                                     # devenv watch mode
```

## Code Quality

```bash
mix format                    # Auto-format
mix format --check-formatted  # Check formatting
mix credo --strict            # Lint
mix dialyzer                  # Type checking
quality                       # devenv shortcut: format check + credo + dialyzer
```

## Architecture

### Layers (top to bottom)

1. **Elixir API** (`lib/denox.ex`) — Public functions: `eval`, `eval_async`, `eval_ts`, `call`, `create_snapshot`, `eval_module`
2. **Pool** (`lib/denox/pool.ex`) — GenServer pool for concurrent V8 runtimes with round-robin dispatch
3. **Run** (`lib/denox/run.ex`) — GenServer managing Deno subprocess (`deno run`) with stdin/stdout streaming
4. **CallbackHandler** (`lib/denox/callback_handler.ex`) — GenServer for JS→Elixir RPC callbacks
5. **Deps/Npm** (`lib/denox/deps.ex`, `lib/denox/npm.ex`) — Dependency management via deno.json and npm/jsr bundling
6. **Native** (`lib/denox/native.ex`) — Rustler NIF binding module
7. **Rust NIF** (`native/denox_nif/src/`) — V8 runtime wrapper, TS transpilation, module loading, timer/callback ops

### Key Rust Files

- `lib.rs` — NIF entry points, `RuntimeResource` (Mutex\<JsRuntime\>), eval pipeline, snapshot creation
- `ts_loader.rs` — `TsModuleLoader` implementing deno_core's `ModuleLoader` trait; handles file:// and https:// imports with caching
- `callback_op.rs` — `op_elixir_call` for JS→Elixir callbacks via mpsc channels
- `timer_op.rs` — Native `op_sleep` for setTimeout/setInterval

### Important Patterns

- All NIF calls run on BEAM dirty CPU schedulers (V8 is single-threaded per runtime)
- Each runtime has its own tokio current_thread runtime for the event loop
- TypeScript is transpile-only via deno_ast (no type checking)
- Async eval wraps code in an async IIFE and pumps the event loop to completion
- Module caching: in-memory HashMap + optional on-disk cache (FNV-1a hash of URL)
- Telemetry events emitted at `[:denox, :eval, :start|:stop|:exception]`

## CI/CD

- `test.yml` — Runs tests on push/PR to main (Elixir 1.18, OTP 28, Rust stable)
- `ci.yml` — Format check, Credo, Dialyzer on push to any branch
- `release.yml` — Manual workflow: builds precompiled NIFs for 4 targets (macOS x86_64/aarch64, Linux x86_64/aarch64), creates GitHub release

## Version Bumping

Version must be updated in both `mix.exs` (@version) and `native/denox_nif/Cargo.toml` simultaneously.
