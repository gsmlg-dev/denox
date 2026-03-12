defmodule Denox.Run do
  @moduledoc """
  Run Deno packages as managed subprocesses.

  Wraps the `deno run` CLI in a GenServer with bidirectional stdio,
  enabling Elixir applications to run full Deno programs (including
  MCP servers, CLI tools, etc.) with OTP supervision.

  ## Examples

      # Run an MCP server
      {:ok, pid} = Denox.Run.start_link(
        package: "@modelcontextprotocol/server-github",
        permissions: :all,
        env: %{"GITHUB_PERSONAL_ACCESS_TOKEN" => token}
      )

      # Send JSON-RPC via stdin
      :ok = Denox.Run.send(pid, ~s|{"jsonrpc":"2.0","method":"initialize","id":1}|)

      # Receive response from stdout
      {:ok, line} = Denox.Run.recv(pid, timeout: 5000)

      # Or subscribe to all output
      Denox.Run.subscribe(pid)
      # => receives {:denox_run_stdout, ^pid, line} messages

      # Run a local script
      {:ok, pid} = Denox.Run.start_link(
        file: "scripts/server.ts",
        permissions: :all
      )

      # Stop the process
      Denox.Run.stop(pid)
  """

  use GenServer

  require Logger

  defstruct [
    :port,
    :os_pid,
    :package,
    :file,
    :exit_status,
    subscribers: [],
    recv_waiters: :queue.new(),
    stdout_buffer: :queue.new()
  ]

  @type t :: %__MODULE__{}

  # --- Public API ---

  @doc """
  Start a managed Deno subprocess.

  ## Options

    - `:package` - JSR/npm package specifier (e.g. `"@modelcontextprotocol/server-github"`)
    - `:file` - local file path to run (alternative to `:package`)
    - `:permissions` - `:all` for `-A`, or keyword list (see `Denox.Run.Permissions`)
    - `:env` - map of environment variables to set
    - `:args` - extra arguments passed after the specifier
    - `:deno_flags` - extra flags passed to `deno run` before the specifier
    - `:name` - GenServer name for registration

  Either `:package` or `:file` must be provided.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    gen_opts = Keyword.take(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Send a line to the subprocess stdin.

  Appends a newline if not already present.
  """
  @spec send(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def send(server, data) do
    GenServer.call(server, {:send, data})
  end

  @doc """
  Receive the next line from stdout.

  Blocks until a line is available or timeout expires.

  ## Options

    - `:timeout` - milliseconds to wait (default: 5000)
  """
  @spec recv(GenServer.server(), keyword()) :: {:ok, String.t()} | {:error, :timeout | :closed}
  def recv(server, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    GenServer.call(server, :recv, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Subscribe the calling process to stdout messages.

  The subscriber receives `{:denox_run_stdout, pid, line}` for each line
  and `{:denox_run_exit, pid, status}` when the process exits.
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server) do
    GenServer.call(server, {:subscribe, self()})
  end

  @doc """
  Unsubscribe the calling process from stdout messages.
  """
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(server) do
    GenServer.call(server, {:unsubscribe, self()})
  end

  @doc """
  Check if the subprocess is still running.
  """
  @spec alive?(GenServer.server()) :: boolean()
  def alive?(server) do
    GenServer.call(server, :alive?)
  end

  @doc """
  Get the OS PID of the subprocess.
  """
  @spec os_pid(GenServer.server()) :: {:ok, non_neg_integer()} | {:error, :not_running}
  def os_pid(server) do
    GenServer.call(server, :os_pid)
  end

  @doc """
  Stop the subprocess gracefully.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    package = Keyword.get(opts, :package)
    file = Keyword.get(opts, :file)

    if is_nil(package) and is_nil(file) do
      raise ArgumentError, "either :package or :file must be provided"
    end

    case find_deno() do
      {:ok, deno_path} ->
        args = build_args(opts)
        env = build_env(opts)

        port =
          Port.open({:spawn_executable, deno_path}, [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            {:args, args},
            {:env, env},
            {:line, 1_048_576}
          ])

        {:ok, os_pid} = extract_os_pid(port)

        state = %__MODULE__{
          port: port,
          os_pid: os_pid,
          package: package,
          file: file
        }

        :telemetry.execute(
          [:denox, :run, :start],
          %{system_time: System.system_time()},
          %{package: package, file: file}
        )

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send, data}, _from, %{port: port, exit_status: nil} = state) do
    data =
      if String.ends_with?(data, "\n"),
        do: data,
        else: data <> "\n"

    Port.command(port, data)
    {:reply, :ok, state}
  end

  def handle_call({:send, _data}, _from, state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call(:recv, from, %{stdout_buffer: buffer} = state) do
    case :queue.out(buffer) do
      {{:value, line}, rest} ->
        {:reply, {:ok, line}, %{state | stdout_buffer: rest}}

      {:empty, _} ->
        if state.exit_status != nil do
          {:reply, {:error, :closed}, state}
        else
          waiters = :queue.in(from, state.recv_waiters)
          {:noreply, %{state | recv_waiters: waiters}}
        end
    end
  end

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: [pid | state.subscribers]}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: List.delete(state.subscribers, pid)}}
  end

  def handle_call(:alive?, _from, state) do
    {:reply, state.exit_status == nil, state}
  end

  def handle_call(:os_pid, _from, %{os_pid: os_pid, exit_status: nil} = state) do
    {:reply, {:ok, os_pid}, state}
  end

  def handle_call(:os_pid, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    state = dispatch_line(line, state)
    {:noreply, state}
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    # Partial line — buffer it until we get eol
    # For simplicity, dispatch partial lines as well
    state = dispatch_line(chunk, state)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    state = %{state | exit_status: status}

    # Notify subscribers
    for pid <- state.subscribers do
      Kernel.send(pid, {:denox_run_exit, self(), status})
    end

    # Reject pending recv waiters
    state = drain_waiters(state)

    :telemetry.execute(
      [:denox, :run, :stop],
      %{system_time: System.system_time()},
      %{package: state.package, file: state.file, exit_status: status}
    )

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: List.delete(state.subscribers, pid)}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{port: port, exit_status: nil}) do
    Port.close(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- Private ---

  defp find_deno do
    case System.find_executable("deno") do
      nil -> {:error, "deno CLI not found in PATH. Install from https://deno.land"}
      path -> {:ok, path}
    end
  end

  defp build_args(opts) do
    package = Keyword.get(opts, :package)
    file = Keyword.get(opts, :file)
    permissions = Keyword.get(opts, :permissions)
    extra_flags = Keyword.get(opts, :deno_flags, [])
    extra_args = Keyword.get(opts, :args, [])

    specifier = resolve_specifier(package || file)

    ["run"] ++
      permissions_to_args(permissions) ++
      extra_flags ++
      [specifier] ++
      extra_args
  end

  # Auto-prefix bare @scope/name with "npm:" since deno run requires it.
  # Specifiers already prefixed (npm:, jsr:, http://, https://, file://)
  # or local file paths are passed through unchanged.
  defp resolve_specifier(spec) do
    cond do
      String.starts_with?(spec, ["npm:", "jsr:", "http://", "https://", "file://"]) ->
        spec

      String.starts_with?(spec, "@") ->
        "npm:#{spec}"

      true ->
        spec
    end
  end

  @permission_flags ~w(
    allow_net allow_env allow_read allow_write allow_run
    allow_ffi allow_sys allow_hrtime
    deny_net deny_env deny_read deny_write deny_run
    deny_ffi deny_sys deny_hrtime
  )a

  defp permissions_to_args(:all), do: ["-A"]
  defp permissions_to_args(nil), do: []

  defp permissions_to_args(perms) when is_list(perms) do
    Enum.flat_map(perms, &permission_to_flag/1)
  end

  defp permission_to_flag({key, true}) when key in @permission_flags do
    [flag_name(key)]
  end

  defp permission_to_flag({key, values}) when key in @permission_flags and is_list(values) do
    ["#{flag_name(key)}=#{Enum.join(values, ",")}"]
  end

  defp permission_to_flag({_key, false}), do: []

  defp permission_to_flag({key, _value}) do
    raise ArgumentError, "unknown permission flag: #{inspect(key)}"
  end

  defp flag_name(key) do
    "--" <> (key |> Atom.to_string() |> String.replace("_", "-"))
  end

  defp build_env(opts) do
    opts
    |> Keyword.get(:env, %{})
    |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  defp extract_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> {:ok, pid}
      nil -> {:ok, 0}
    end
  end

  defp dispatch_line(line, state) do
    # Notify subscribers
    for pid <- state.subscribers do
      Kernel.send(pid, {:denox_run_stdout, self(), line})
    end

    # Try to fulfill a pending recv waiter
    case :queue.out(state.recv_waiters) do
      {{:value, from}, rest} ->
        GenServer.reply(from, {:ok, line})
        %{state | recv_waiters: rest}

      {:empty, _} ->
        %{state | stdout_buffer: :queue.in(line, state.stdout_buffer)}
    end
  end

  defp drain_waiters(state) do
    case :queue.out(state.recv_waiters) do
      {{:value, from}, rest} ->
        GenServer.reply(from, {:error, :closed})
        drain_waiters(%{state | recv_waiters: rest})

      {:empty, _} ->
        state
    end
  end
end
