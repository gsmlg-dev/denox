defmodule Denox do
  @moduledoc """
  Denox embeds a TypeScript/JavaScript runtime (Deno/V8) into Elixir via a Rustler NIF.
  """

  alias Denox.Native

  @doc """
  Create a new JavaScript runtime.

  Returns `{:ok, runtime}` or `{:error, message}`.
  """
  def runtime(opts \\ []) do
    _ = opts
    Native.runtime_new()
  end

  @doc """
  Evaluate JavaScript code in the given runtime.

  Returns `{:ok, json_string}` or `{:error, message}`.
  """
  def eval(rt, code) do
    Native.eval(rt, code)
  end

  @doc """
  Execute JavaScript code, ignoring the return value.

  Returns `:ok` or `{:error, message}`.
  """
  def exec(rt, code) do
    case Native.eval(rt, code) do
      {:ok, _} -> :ok
      {:error, msg} -> {:error, msg}
    end
  end

  @doc """
  Call a named JavaScript function with arguments.

  Arguments are serialized to JSON. Returns `{:ok, json_string}` or `{:error, message}`.
  """
  def call(rt, func_name, args \\ []) do
    args_json = Jason.encode!(args)
    Native.call_function(rt, func_name, args_json)
  end

  @doc """
  Evaluate JavaScript code and decode the JSON result to Elixir terms.

  Returns `{:ok, term}` or `{:error, message}`.
  """
  def eval_decode(rt, code) do
    with {:ok, json} <- eval(rt, code) do
      Jason.decode(json)
    end
  end

  @doc """
  Call a named JavaScript function and decode the JSON result.

  Returns `{:ok, term}` or `{:error, message}`.
  """
  def call_decode(rt, func_name, args \\ []) do
    with {:ok, json} <- call(rt, func_name, args) do
      Jason.decode(json)
    end
  end
end
