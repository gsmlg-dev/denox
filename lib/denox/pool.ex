defmodule Denox.Pool do
  @moduledoc """
  GenServer-based pool of JavaScript runtimes for concurrent workloads.

  V8 isolates are single-threaded, so the pool round-robins requests
  across N runtimes to achieve parallelism.

  ## Usage

      # In your supervision tree
      children = [
        {Denox.Pool, name: :js_pool, size: 4}
      ]

      # Then use the pool
      {:ok, result} = Denox.Pool.eval(:js_pool, "1 + 2")
      {:ok, result} = Denox.Pool.eval_ts(:js_pool, "const x: number = 42; x")
  """
  use GenServer

  @type pool :: GenServer.server()

  # --- Client API ---

  @doc """
  Start a pool of runtimes.

  Options:
    - `:name` - registered name for the pool (required)
    - `:size` - number of runtimes (default: `System.schedulers_online()`)
    - `:sandbox` - if true, disable built-in extensions in all runtimes
    - `:base_dir` - base directory for module resolution
    - `:cache_dir` - cache directory for remote modules
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc "Evaluate JavaScript code using the next runtime in the pool."
  @spec eval(pool(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def eval(pool, code) do
    GenServer.call(pool, {:eval, code}, :infinity)
  end

  @doc "Evaluate TypeScript code using the next runtime in the pool."
  @spec eval_ts(pool(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def eval_ts(pool, code) do
    GenServer.call(pool, {:eval_ts, code}, :infinity)
  end

  @doc "Evaluate JavaScript code asynchronously (pumps event loop)."
  @spec eval_async(pool(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def eval_async(pool, code) do
    GenServer.call(pool, {:eval_async, code}, :infinity)
  end

  @doc "Evaluate TypeScript code asynchronously."
  @spec eval_ts_async(pool(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def eval_ts_async(pool, code) do
    GenServer.call(pool, {:eval_ts_async, code}, :infinity)
  end

  @doc "Execute JavaScript code, ignoring the return value."
  @spec exec(pool(), String.t()) :: :ok | {:error, String.t()}
  def exec(pool, code) do
    GenServer.call(pool, {:exec, code}, :infinity)
  end

  @doc "Call a named JavaScript function with arguments."
  @spec call(pool(), String.t(), list()) :: {:ok, String.t()} | {:error, String.t()}
  def call(pool, func_name, args \\ []) do
    GenServer.call(pool, {:call, func_name, args}, :infinity)
  end

  @doc "Call a named async JavaScript function with arguments."
  @spec call_async(pool(), String.t(), list()) :: {:ok, String.t()} | {:error, String.t()}
  def call_async(pool, func_name, args \\ []) do
    GenServer.call(pool, {:call_async, func_name, args}, :infinity)
  end

  @doc "Evaluate and decode JSON result."
  @spec eval_decode(pool(), String.t()) :: {:ok, term()} | {:error, term()}
  def eval_decode(pool, code) do
    GenServer.call(pool, {:eval_decode, code}, :infinity)
  end

  @doc "Read and evaluate a JavaScript or TypeScript file."
  @spec eval_file(pool(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def eval_file(pool, path, opts \\ []) do
    GenServer.call(pool, {:eval_file, path, opts}, :infinity)
  end

  @doc "Load a bundled JS file into all runtimes in the pool."
  @spec load_npm(pool(), String.t()) :: :ok | {:error, String.t()}
  def load_npm(pool, bundle_path) do
    GenServer.call(pool, {:load_npm, bundle_path}, :infinity)
  end

  @doc "Return the pool size."
  @spec size(pool()) :: non_neg_integer()
  def size(pool) do
    GenServer.call(pool, :size)
  end

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    pool_size = Keyword.get(opts, :size, System.schedulers_online())

    runtime_opts =
      opts
      |> Keyword.take([:base_dir, :cache_dir, :sandbox, :import_map, :callback_pid])

    runtimes =
      for _ <- 1..pool_size do
        case Denox.runtime(runtime_opts) do
          {:ok, rt} -> rt
          {:error, msg} -> raise "Failed to create runtime: #{msg}"
        end
      end

    {:ok,
     %{
       runtimes: List.to_tuple(runtimes),
       size: pool_size,
       index: 0
     }}
  end

  @impl true
  def handle_call({:eval, code}, _from, state) do
    {rt, state} = next_runtime(state)
    {:reply, Denox.eval(rt, code), state}
  end

  def handle_call({:eval_ts, code}, _from, state) do
    {rt, state} = next_runtime(state)
    {:reply, Denox.eval_ts(rt, code), state}
  end

  def handle_call({:eval_async, code}, _from, state) do
    {rt, state} = next_runtime(state)
    {:reply, Denox.eval_async(rt, code), state}
  end

  def handle_call({:eval_ts_async, code}, _from, state) do
    {rt, state} = next_runtime(state)
    {:reply, Denox.eval_ts_async(rt, code), state}
  end

  def handle_call({:exec, code}, _from, state) do
    {rt, state} = next_runtime(state)
    {:reply, Denox.exec(rt, code), state}
  end

  def handle_call({:call, func_name, args}, _from, state) do
    {rt, state} = next_runtime(state)
    {:reply, Denox.call(rt, func_name, args), state}
  end

  def handle_call({:call_async, func_name, args}, _from, state) do
    {rt, state} = next_runtime(state)
    {:reply, Denox.call_async(rt, func_name, args), state}
  end

  def handle_call({:eval_decode, code}, _from, state) do
    {rt, state} = next_runtime(state)
    {:reply, Denox.eval_decode(rt, code), state}
  end

  def handle_call({:eval_file, path, opts}, _from, state) do
    {rt, state} = next_runtime(state)
    {:reply, Denox.eval_file(rt, path, opts), state}
  end

  def handle_call({:load_npm, bundle_path}, _from, state) do
    case File.read(bundle_path) do
      {:ok, code} ->
        results =
          for i <- 0..(state.size - 1) do
            rt = elem(state.runtimes, i)
            Denox.exec(rt, code)
          end

        case Enum.find(results, &match?({:error, _}, &1)) do
          nil -> {:reply, :ok, state}
          error -> {:reply, error, state}
        end

      {:error, reason} ->
        {:reply, {:error, "Failed to read bundle #{bundle_path}: #{reason}"}, state}
    end
  end

  def handle_call(:size, _from, state) do
    {:reply, state.size, state}
  end

  # --- Private ---

  defp next_runtime(state) do
    rt = elem(state.runtimes, state.index)
    next_index = rem(state.index + 1, state.size)
    {rt, %{state | index: next_index}}
  end
end
