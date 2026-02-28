defmodule Denox do
  @moduledoc """
  Denox embeds a TypeScript/JavaScript runtime (Deno/V8) into Elixir via a Rustler NIF.
  """

  alias Denox.Native

  @doc """
  Create a new JavaScript runtime.

  Options:
    - `:base_dir` - base directory for resolving relative module imports

  Returns `{:ok, runtime}` or `{:error, message}`.
  """
  def runtime(opts \\ []) do
    base_dir = Keyword.get(opts, :base_dir, "")
    Native.runtime_new(base_dir)
  end

  # --- Synchronous eval (no event loop) ---

  @doc """
  Evaluate JavaScript code in the given runtime.

  Returns `{:ok, json_string}` or `{:error, message}`.
  """
  def eval(rt, code), do: Native.eval(rt, code, false)

  @doc """
  Evaluate TypeScript code in the given runtime.
  Transpiles via deno_ast/swc then evaluates. No type-checking.

  Returns `{:ok, json_string}` or `{:error, message}`.
  """
  def eval_ts(rt, code), do: Native.eval(rt, code, true)

  @doc """
  Execute JavaScript code, ignoring the return value.

  Returns `:ok` or `{:error, message}`.
  """
  def exec(rt, code) do
    case Native.eval(rt, code, false) do
      {:ok, _} -> :ok
      {:error, msg} -> {:error, msg}
    end
  end

  @doc """
  Execute TypeScript code, ignoring the return value.

  Returns `:ok` or `{:error, message}`.
  """
  def exec_ts(rt, code) do
    case Native.eval(rt, code, true) do
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
  def eval_async(rt, code), do: Native.eval_async(rt, code, false)

  @doc """
  Evaluate TypeScript code asynchronously.

  Returns `{:ok, json_string}` or `{:error, message}`.
  """
  def eval_ts_async(rt, code), do: Native.eval_async(rt, code, true)

  # --- Module loading ---

  @doc """
  Load and evaluate an ES module file. Supports .ts/.js with import/export.

  Returns `{:ok, "undefined"}` or `{:error, message}`.
  """
  def eval_module(rt, path), do: Native.eval_module(rt, path)

  # --- Function calls ---

  @doc """
  Call a named JavaScript function with arguments.

  Arguments are serialized to JSON. Returns `{:ok, json_string}` or `{:error, message}`.
  """
  def call(rt, func_name, args \\ []) do
    args_json = Jason.encode!(args)
    Native.call_function(rt, func_name, args_json)
  end

  @doc """
  Call a named async JavaScript function with arguments.

  Returns `{:ok, json_string}` or `{:error, message}`.
  """
  def call_async(rt, func_name, args \\ []) do
    args_json = Jason.encode!(args)
    code = "return await ((args) => #{func_name}(...args))(#{args_json})"
    Native.eval_async(rt, code, false)
  end

  # --- Decode variants ---

  @doc """
  Evaluate JavaScript code and decode the JSON result to Elixir terms.
  """
  def eval_decode(rt, code) do
    with {:ok, json} <- eval(rt, code), do: Jason.decode(json)
  end

  @doc """
  Evaluate TypeScript code and decode the JSON result to Elixir terms.
  """
  def eval_ts_decode(rt, code) do
    with {:ok, json} <- eval_ts(rt, code), do: Jason.decode(json)
  end

  @doc """
  Call a named JavaScript function and decode the JSON result.
  """
  def call_decode(rt, func_name, args \\ []) do
    with {:ok, json} <- call(rt, func_name, args), do: Jason.decode(json)
  end

  @doc """
  Call a named async JavaScript function and decode the JSON result.
  """
  def call_async_decode(rt, func_name, args \\ []) do
    with {:ok, json} <- call_async(rt, func_name, args), do: Jason.decode(json)
  end
end
