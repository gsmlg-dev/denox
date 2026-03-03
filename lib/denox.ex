defmodule Denox do
  @moduledoc """
  Denox embeds a TypeScript/JavaScript runtime (Deno/V8) into Elixir via a Rustler NIF.

  ## Telemetry Events

  Denox emits the following telemetry events:

    * `[:denox, :eval, :start]` — emitted before evaluating code
      * Measurements: `%{system_time: integer}`
      * Metadata: `%{type: :eval | :eval_ts | :eval_async | :eval_ts_async | :eval_module | :eval_file}`

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
    - `:sandbox` - if true, disable built-in extensions (fs/net ops) for reduced attack surface
    - `:cache_dir` - on-disk cache directory for remote module fetches

  Returns `{:ok, runtime}` or `{:error, message}`.
  """
  @spec runtime(keyword()) :: {:ok, runtime()} | {:error, String.t()}
  def runtime(opts \\ []) do
    base_dir = Keyword.get(opts, :base_dir, "")
    sandbox = Keyword.get(opts, :sandbox, false)
    cache_dir = Keyword.get(opts, :cache_dir, "")
    Native.runtime_new(base_dir, sandbox, cache_dir)
  end

  # --- Synchronous eval (no event loop) ---

  @doc """
  Evaluate JavaScript code in the given runtime.

  Returns `{:ok, json_string}` or `{:error, message}`.
  """
  @spec eval(runtime(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def eval(rt, code) do
    telemetry_span(:eval, fn -> Native.eval(rt, code, false) end)
  end

  @doc """
  Evaluate TypeScript code in the given runtime.
  Transpiles via deno_ast/swc then evaluates. No type-checking.

  Returns `{:ok, json_string}` or `{:error, message}`.
  """
  @spec eval_ts(runtime(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def eval_ts(rt, code) do
    telemetry_span(:eval_ts, fn -> Native.eval(rt, code, true) end)
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

  # --- Async eval (pumps event loop — for import(), await, Promises) ---

  @doc """
  Evaluate JavaScript code asynchronously, pumping the event loop.
  Use this for dynamic `import()`, `await`, and Promise-based code.

  Returns `{:ok, json_string}` or `{:error, message}`.
  """
  @spec eval_async(runtime(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def eval_async(rt, code) do
    telemetry_span(:eval_async, fn -> Native.eval_async(rt, code, false) end)
  end

  @doc """
  Evaluate TypeScript code asynchronously.

  Returns `{:ok, json_string}` or `{:error, message}`.
  """
  @spec eval_ts_async(runtime(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def eval_ts_async(rt, code) do
    telemetry_span(:eval_ts_async, fn -> Native.eval_async(rt, code, true) end)
  end

  # --- Module loading ---

  @doc """
  Load and evaluate an ES module file. Supports .ts/.js with import/export.

  Returns `{:ok, "undefined"}` or `{:error, message}`.
  """
  @spec eval_module(runtime(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def eval_module(rt, path) do
    telemetry_span(:eval_module, fn -> Native.eval_module(rt, path) end)
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

    telemetry_span(:eval_file, fn ->
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
    args_json = Jason.encode!(args)
    Native.call_function(rt, func_name, args_json)
  end

  @doc """
  Call a named async JavaScript function with arguments.

  Returns `{:ok, json_string}` or `{:error, message}`.
  """
  @spec call_async(runtime(), String.t(), list()) :: {:ok, String.t()} | {:error, String.t()}
  def call_async(rt, func_name, args \\ []) do
    args_json = Jason.encode!(args)
    code = "return await ((args) => #{func_name}(...args))(#{args_json})"
    Native.eval_async(rt, code, false)
  end

  # --- Decode variants ---

  @doc """
  Evaluate JavaScript code and decode the JSON result to Elixir terms.
  """
  @spec eval_decode(runtime(), String.t()) :: {:ok, term()} | {:error, term()}
  def eval_decode(rt, code) do
    with {:ok, json} <- eval(rt, code), do: Jason.decode(json)
  end

  @doc """
  Evaluate TypeScript code and decode the JSON result to Elixir terms.
  """
  @spec eval_ts_decode(runtime(), String.t()) :: {:ok, term()} | {:error, term()}
  def eval_ts_decode(rt, code) do
    with {:ok, json} <- eval_ts(rt, code), do: Jason.decode(json)
  end

  @doc """
  Call a named JavaScript function and decode the JSON result.
  """
  @spec call_decode(runtime(), String.t(), list()) :: {:ok, term()} | {:error, term()}
  def call_decode(rt, func_name, args \\ []) do
    with {:ok, json} <- call(rt, func_name, args), do: Jason.decode(json)
  end

  @doc """
  Call a named async JavaScript function and decode the JSON result.
  """
  @spec call_async_decode(runtime(), String.t(), list()) :: {:ok, term()} | {:error, term()}
  def call_async_decode(rt, func_name, args \\ []) do
    with {:ok, json} <- call_async(rt, func_name, args), do: Jason.decode(json)
  end

  # --- Private ---

  defp ts_extension?(path) do
    ext = Path.extname(path)
    ext in [".ts", ".tsx", ".mts", ".cts"]
  end

  defp telemetry_span(type, fun) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:denox, :eval, :start],
      %{system_time: System.system_time()},
      %{type: type}
    )

    case fun.() do
      {:ok, result} ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:denox, :eval, :stop],
          %{duration: duration},
          %{type: type}
        )

        {:ok, result}

      {:error, reason} = error ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:denox, :eval, :exception],
          %{duration: duration},
          %{type: type, kind: :error, reason: reason}
        )

        error
    end
  end
end
