defmodule Denox do
  @moduledoc """
  Denox embeds a TypeScript/JavaScript runtime (Deno/V8) into Elixir via a Rustler NIF.

  ## Telemetry Events

  Denox emits the following telemetry events:

    * `[:denox, :eval, :start]` — emitted before evaluating code
      * Measurements: `%{system_time: integer}`
      * Metadata: `%{type: atom}` — type is the function name atom (e.g. `:eval`, `:eval_ts`,
        `:eval_async`, `:eval_ts_async`, `:eval_module`, `:eval_file`, `:call`,
        `:call_async`, `:eval_async_decode`, `:eval_ts_async_decode`, `:call_async_decode`)
        Note: `*_decode` sync variants (`:eval_decode`, `:call_decode`, etc.) emit the base
        type (`:eval`, `:call`, etc.) since they delegate to the base function.

    * `[:denox, :eval, :stop]` — emitted after successful evaluation
      * Measurements: `%{duration: integer}` (native time units)
      * Metadata: `%{type: atom}`

    * `[:denox, :eval, :exception]` — emitted on evaluation error
      * Measurements: `%{duration: integer}`
      * Metadata: `%{type: atom, kind: :error, reason: term}`
  """

  alias Denox.Native

  @type runtime :: reference()

  @doc """
  Create a new JavaScript runtime.

  Options:
    - `:base_dir` - base directory for resolving relative module imports
    - `:sandbox` - (deprecated) if true, deny all permissions. Use `:permissions` instead
    - `:permissions` - permission mode:
      - `:all` — allow everything (default)
      - `:none` — deny everything (same as `sandbox: true`)
      - keyword list — granular permissions (e.g. `[allow_net: true, allow_read: ["/tmp"]]`)
    - `:cache_dir` - on-disk cache directory for remote module fetches
    - `:import_map` - map of bare specifiers to resolved URLs/paths (e.g. `%{"lodash" => "https://esm.sh/lodash"}`)
    - `:callback_pid` - PID of the process that handles JS→Elixir callbacks (enables `Denox.callback()` in JS)
    - `:snapshot` - V8 snapshot binary for faster cold start (created via `create_snapshot/2`)

  Returns `{:ok, runtime}` or `{:error, message}`.
  """
  @spec runtime(keyword()) :: {:ok, runtime()} | {:error, String.t()}
  def runtime(opts \\ []) do
    base_dir = Keyword.get(opts, :base_dir, "")
    sandbox = Keyword.get(opts, :sandbox, false)

    if sandbox do
      IO.warn("the :sandbox option is deprecated, use permissions: :none instead")
    end

    cache_dir = Keyword.get(opts, :cache_dir, "")
    callback_pid = Keyword.get(opts, :callback_pid)
    snapshot = Keyword.get(opts, :snapshot, <<>>)

    import_map_json =
      case Keyword.get(opts, :import_map) do
        nil -> ""
        map when is_map(map) -> Denox.JSON.encode!(map)
      end

    permissions_json = build_permissions_json(opts, sandbox)

    Native.runtime_new(
      base_dir,
      sandbox,
      cache_dir,
      import_map_json,
      callback_pid,
      snapshot,
      permissions_json
    )
  end

  @doc """
  Create a V8 snapshot from setup code.

  The snapshot captures all global state (variables, functions, etc.)
  after executing the setup code. Load it with `runtime(snapshot: bytes)`
  for faster cold starts.

  Options:
    - `:transpile` - if true, transpile TypeScript before executing (default: false)

  Returns `{:ok, snapshot_bytes}` or `{:error, message}`.

  ## Example

      {:ok, snapshot} = Denox.create_snapshot("globalThis.helper = (x) => x * 2")
      {:ok, rt} = Denox.runtime(snapshot: snapshot)
      {:ok, "10"} = Denox.call(rt, "helper", [5])
  """
  @spec create_snapshot(String.t(), keyword()) :: {:ok, binary()} | {:error, String.t()}
  def create_snapshot(setup_code, opts \\ []) do
    transpile = Keyword.get(opts, :transpile, false)
    Native.create_snapshot(setup_code, transpile)
  end

  # --- Eval (pumps event loop, resolves Promises) ---

  @doc """
  Evaluate JavaScript code in the given runtime.

  Pumps the event loop and resolves Promises automatically.
  Supports `import()`, `setTimeout`, and other async operations.

  Returns `{:ok, json_string}` or `{:error, message}`.
  """
  @spec eval(runtime(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def eval(rt, code) do
    Denox.Telemetry.span(:eval, fn -> Native.eval(rt, code, false) end)
  end

  @doc """
  Evaluate TypeScript code in the given runtime.
  Transpiles via deno_ast/swc then evaluates. No type-checking.

  Pumps the event loop and resolves Promises automatically.

  Returns `{:ok, json_string}` or `{:error, message}`.
  """
  @spec eval_ts(runtime(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def eval_ts(rt, code) do
    Denox.Telemetry.span(:eval_ts, fn -> Native.eval(rt, code, true) end)
  end

  @doc """
  Execute JavaScript code, ignoring the return value.

  Returns `:ok` or `{:error, message}`.
  """
  @spec exec(runtime(), String.t()) :: :ok | {:error, String.t()}
  def exec(rt, code) do
    case eval(rt, code) do
      {:ok, _} -> :ok
      {:error, msg} -> {:error, msg}
    end
  end

  @doc """
  Execute TypeScript code, ignoring the return value.

  Returns `:ok` or `{:error, message}`.
  """
  @spec exec_ts(runtime(), String.t()) :: :ok | {:error, String.t()}
  def exec_ts(rt, code) do
    case eval_ts(rt, code) do
      {:ok, _} -> :ok
      {:error, msg} -> {:error, msg}
    end
  end

  # --- Async eval (returns Task for concurrent execution) ---

  @doc """
  Evaluate JavaScript code as an ES module, returning a `Task`.

  The code is evaluated as a proper ES module, so static `import`/`export`
  declarations and top-level `await` work natively. Use `export default`
  to return a value.

  Returns a `Task` that resolves to `{:ok, json_string}` or `{:error, message}`.

  ## Example

      task = Denox.eval_async(rt, "const status = (await fetch('https://httpbin.org/get')).status; export default status;")
      {:ok, "200"} = Task.await(task)

      # Static imports work:
      task = Denox.eval_async(rt, \"\"\"
        import { something } from './my_module.js';
        export default something;
      \"\"\")

  """
  @spec eval_async(runtime(), String.t()) :: Task.t()
  def eval_async(rt, code) do
    Task.async(fn ->
      Denox.Telemetry.span(:eval_async, fn -> Native.eval_async(rt, code, false) end)
    end)
  end

  @doc """
  Evaluate TypeScript code as an ES module, returning a `Task`.

  Supports static `import`/`export` declarations and top-level `await`.
  Use `export default` to return a value.

  Returns a `Task` that resolves to `{:ok, json_string}` or `{:error, message}`.
  """
  @spec eval_ts_async(runtime(), String.t()) :: Task.t()
  def eval_ts_async(rt, code) do
    Task.async(fn ->
      Denox.Telemetry.span(:eval_ts_async, fn -> Native.eval_async(rt, code, true) end)
    end)
  end

  # --- Module loading ---

  @doc """
  Load and evaluate an ES module file. Supports .ts/.js with import/export.

  Returns `{:ok, "undefined"}` or `{:error, message}`.
  """
  @spec eval_module(runtime(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def eval_module(rt, path) do
    Denox.Telemetry.span(:eval_module, fn -> Native.eval_module(rt, path) end)
  end

  # --- File evaluation ---

  @doc """
  Read and evaluate a JavaScript or TypeScript file.

  Simpler than `eval_module/2` — no import/export support, just script execution.
  TypeScript files (.ts, .tsx) are automatically transpiled.

  Returns `{:ok, json_string}` or `{:error, message}`.
  """
  @spec eval_file(runtime(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def eval_file(rt, path, opts \\ []) do
    transpile = Keyword.get(opts, :transpile, ts_extension?(path))

    Denox.Telemetry.span(:eval_file, fn ->
      case File.read(path) do
        {:ok, code} -> Native.eval(rt, code, transpile)
        {:error, reason} -> {:error, "Failed to read #{path}: #{reason}"}
      end
    end)
  end

  # --- Function calls ---

  @doc """
  Call a named JavaScript function with arguments.

  Arguments are serialized to JSON. Returns `{:ok, json_string}` or `{:error, message}`.
  """
  @spec call(runtime(), String.t(), list()) :: {:ok, String.t()} | {:error, String.t()}
  def call(rt, func_name, args \\ []) do
    args_json = Denox.JSON.encode!(args)
    Denox.Telemetry.span(:call, fn -> Native.call_function(rt, func_name, args_json) end)
  end

  @doc """
  Call a named async JavaScript function with arguments, returning a `Task`.

  Use `Task.await/2` to get the result.

  Returns a `Task` that resolves to `{:ok, json_string}` or `{:error, message}`.
  """
  @spec call_async(runtime(), String.t(), list()) :: Task.t()
  def call_async(rt, func_name, args \\ []) do
    args_json = Denox.JSON.encode!(args)
    code = "export default await ((args) => #{func_name}(...args))(#{args_json})"

    Task.async(fn ->
      Denox.Telemetry.span(:call_async, fn -> Native.eval_async(rt, code, false) end)
    end)
  end

  # --- Await helper ---

  @doc """
  Await the result of an async evaluation task.

  Delegates to `Task.await/2`. Use with tasks returned by
  `eval_async/2`, `eval_ts_async/2`, `call_async/3`, and `call_async_decode/3`.

  ## Example

      Denox.eval_async(rt, "export default await Promise.resolve(42)")
      |> Denox.await()
      #=> {:ok, "42"}

  """
  defdelegate await(task, timeout \\ 5000), to: Task

  # --- Decode variants ---

  @doc """
  Evaluate JavaScript code and decode the JSON result to Elixir terms.
  """
  @spec eval_decode(runtime(), String.t()) :: {:ok, term()} | {:error, term()}
  def eval_decode(rt, code) do
    with {:ok, json} <- eval(rt, code), do: Denox.JSON.decode(json)
  end

  @doc """
  Evaluate TypeScript code and decode the JSON result to Elixir terms.
  """
  @spec eval_ts_decode(runtime(), String.t()) :: {:ok, term()} | {:error, term()}
  def eval_ts_decode(rt, code) do
    with {:ok, json} <- eval_ts(rt, code), do: Denox.JSON.decode(json)
  end

  @doc """
  Call a named JavaScript function and decode the JSON result.
  """
  @spec call_decode(runtime(), String.t(), list()) :: {:ok, term()} | {:error, term()}
  def call_decode(rt, func_name, args \\ []) do
    with {:ok, json} <- call(rt, func_name, args), do: Denox.JSON.decode(json)
  end

  @doc """
  Call a named async JavaScript function and decode the JSON result.

  Returns a `Task` that resolves to `{:ok, term()}` or `{:error, term()}`.
  """
  @spec call_async_decode(runtime(), String.t(), list()) :: Task.t()
  def call_async_decode(rt, func_name, args \\ []) do
    args_json = Denox.JSON.encode!(args)
    code = "export default await ((args) => #{func_name}(...args))(#{args_json})"
    Task.async(fn -> do_call_async_decode(rt, code) end)
  end

  @doc """
  Evaluate JavaScript code asynchronously and decode the JSON result.

  Returns a `Task` that resolves to `{:ok, term()}` or `{:error, term()}`.
  """
  @spec eval_async_decode(runtime(), String.t()) :: Task.t()
  def eval_async_decode(rt, code) do
    Task.async(fn -> do_eval_async_decode(rt, code) end)
  end

  @doc """
  Evaluate TypeScript code asynchronously and decode the JSON result.

  Returns a `Task` that resolves to `{:ok, term()}` or `{:error, term()}`.
  """
  @spec eval_ts_async_decode(runtime(), String.t()) :: Task.t()
  def eval_ts_async_decode(rt, code) do
    Task.async(fn -> do_eval_ts_async_decode(rt, code) end)
  end

  @doc """
  Read and evaluate a JavaScript or TypeScript file asynchronously.

  Returns a `Task` that resolves to `{:ok, json_string}` or `{:error, message}`.
  """
  @spec eval_file_async(runtime(), String.t(), keyword()) :: Task.t()
  def eval_file_async(rt, path, opts \\ []) do
    transpile = Keyword.get(opts, :transpile, ts_extension?(path))
    Task.async(fn -> do_eval_file_async(rt, path, transpile) end)
  end

  @doc """
  Read and evaluate a JavaScript or TypeScript file and decode the JSON result.

  Returns `{:ok, term()}` or `{:error, term()}`.
  """
  @spec eval_file_decode(runtime(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def eval_file_decode(rt, path, opts \\ []) do
    with {:ok, json} <- eval_file(rt, path, opts), do: Denox.JSON.decode(json)
  end

  @doc """
  Read and evaluate a JavaScript or TypeScript file asynchronously and decode the JSON result.

  Returns a `Task` that resolves to `{:ok, term()}` or `{:error, term()}`.
  """
  @spec eval_file_async_decode(runtime(), String.t(), keyword()) :: Task.t()
  def eval_file_async_decode(rt, path, opts \\ []) do
    transpile = Keyword.get(opts, :transpile, ts_extension?(path))
    Task.async(fn -> do_eval_file_async_decode(rt, path, transpile) end)
  end

  # --- Private ---

  defp do_call_async_decode(rt, code) do
    with {:ok, json} <-
           Denox.Telemetry.span(:call_async_decode, fn -> Native.eval_async(rt, code, false) end),
         do: Denox.JSON.decode(json)
  end

  defp do_eval_file_async(rt, path, transpile) do
    case File.read(path) do
      {:ok, code} -> Native.eval_async(rt, code, transpile)
      {:error, reason} -> {:error, "Failed to read #{path}: #{reason}"}
    end
  end

  defp do_eval_async_decode(rt, code) do
    with {:ok, json} <-
           Denox.Telemetry.span(:eval_async_decode, fn -> Native.eval_async(rt, code, false) end),
         do: Denox.JSON.decode(json)
  end

  defp do_eval_ts_async_decode(rt, code) do
    with {:ok, json} <-
           Denox.Telemetry.span(:eval_ts_async_decode, fn -> Native.eval_async(rt, code, true) end),
         do: Denox.JSON.decode(json)
  end

  defp do_eval_file_async_decode(rt, path, transpile) do
    case File.read(path) do
      {:ok, code} ->
        with {:ok, json} <- Native.eval_async(rt, code, transpile), do: Denox.JSON.decode(json)

      {:error, reason} ->
        {:error, "Failed to read #{path}: #{reason}"}
    end
  end

  defp build_permissions_json(opts, sandbox) do
    permissions = Keyword.get(opts, :permissions)

    cond do
      permissions == :all -> Denox.JSON.encode!(%{mode: "allow_all"})
      permissions == :none -> Denox.JSON.encode!(%{mode: "deny_all"})
      is_list(permissions) -> build_granular_permissions_json(permissions)
      sandbox -> Denox.JSON.encode!(%{mode: "deny_all"})
      true -> ""
    end
  end

  defp build_granular_permissions_json(perms) do
    base = %{mode: "granular"}

    config =
      Enum.reduce(perms, base, fn {key, value}, acc ->
        key_str = Atom.to_string(key)
        Map.put(acc, key_str, value)
      end)

    Denox.JSON.encode!(config)
  end

  defp ts_extension?(path) do
    ext = Path.extname(path)
    ext in [".ts", ".tsx", ".mts", ".cts"]
  end
end
