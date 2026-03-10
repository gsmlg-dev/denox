defmodule Denox.CallbackHandler do
  @moduledoc """
  GenServer that handles JS → Elixir callbacks for a Denox runtime.

  When JavaScript code calls `Denox.callback(name, arg1, arg2, ...)`,
  this handler receives the request, invokes the registered Elixir function,
  and sends the result back to JavaScript.

  ## Usage

      # 1. Start a callback handler with named functions
      {:ok, handler} = Denox.CallbackHandler.start_link(
        callbacks: %{
          "greet" => fn [name] -> "Hello, \#{name}!" end,
          "add" => fn [a, b] -> a + b end
        }
      )

      # 2. Create a runtime with the handler's PID
      {:ok, rt} = Denox.runtime(callback_pid: handler)

      # 3. JavaScript can now call back to Elixir
      {:ok, result} = Denox.eval(rt, ~s[Denox.callback("greet", "Alice")])
      # result => "\"Hello, Alice!\""

  ## Convenience

  Use `Denox.CallbackHandler.runtime/1` to create both handler and runtime in one call:

      {:ok, rt, handler} = Denox.CallbackHandler.runtime(
        callbacks: %{"add" => fn [a, b] -> a + b end},
        base_dir: "/some/path"
      )
  """

  use GenServer

  alias Denox.Native

  @doc """
  Start a callback handler.

  Options:
    - `:callbacks` - map of callback name (string) to function (required).
      Each function receives a list of decoded JSON arguments.
  """
  def start_link(opts) do
    callbacks = Keyword.fetch!(opts, :callbacks)
    GenServer.start_link(__MODULE__, %{callbacks: callbacks})
  end

  @doc """
  Create a callback handler and runtime together.

  Options:
    - `:callbacks` - map of callback name to function (required)
    - All other options are passed to `Denox.runtime/1`

  Returns `{:ok, runtime, handler_pid}` or `{:error, reason}`.
  """
  @spec runtime(keyword()) :: {:ok, Denox.runtime(), pid()} | {:error, String.t()}
  def runtime(opts) do
    {callbacks, runtime_opts} = Keyword.pop!(opts, :callbacks)

    with {:ok, handler} <- start_link(callbacks: callbacks),
         {:ok, rt} <- Denox.runtime(Keyword.put(runtime_opts, :callback_pid, handler)) do
      {:ok, rt, handler}
    end
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_info({:denox_callback, resource, callback_id, name, args_json}, state) do
    callbacks = state.callbacks

    case Map.get(callbacks, name) do
      nil ->
        Native.callback_error(resource, callback_id, "Unknown callback: #{name}")

      fun when is_function(fun) ->
        try do
          args = Denox.JSON.decode!(args_json)
          result = fun.(args)
          result_json = Denox.JSON.encode!(result)
          Native.callback_reply(resource, callback_id, result_json)
        rescue
          e ->
            Native.callback_error(resource, callback_id, Exception.message(e))
        end
    end

    {:noreply, state}
  end
end
