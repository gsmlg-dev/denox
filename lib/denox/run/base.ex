defmodule Denox.Run.Base do
  @moduledoc false
  # Shared GenServer dispatch logic for Run modules.
  #
  # Provides the common public API (send, recv, subscribe, etc.)
  # and stdout dispatch logic. Backend modules implement:
  #
  #   - init_backend/1 — start the backend (NIF resource or Port)
  #   - send_backend/2 — write data to the backend
  #   - stop_backend/1 — shut down the backend
  #   - alive_backend?/1 — check if backend is running

  @callback init_backend(keyword()) ::
              {:ok, backend_state :: term()} | {:error, term()}

  @callback send_backend(backend_state :: term(), String.t()) ::
              :ok | {:error, term()}

  @callback stop_backend(backend_state :: term()) :: :ok

  @callback alive_backend?(backend_state :: term()) :: boolean()

  defmacro __using__(opts) do
    backend_type = Keyword.fetch!(opts, :backend)

    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote location: :keep do
      @behaviour Denox.Run.Base

      use GenServer

      require Logger

      defstruct [
        :backend_state,
        :package,
        :file,
        :exit_status,
        subscribers: [],
        recv_waiters: :queue.new(),
        stdout_buffer: :queue.new()
      ]

      @type t :: %__MODULE__{}

      @backend_type unquote(backend_type)

      # --- Public API ---

      @doc """
      Start a managed Deno runtime.

      ## Options

        - `:package` - JSR/npm package specifier
        - `:file` - local file path to run
        - `:permissions` - `:all` for `-A`, or keyword list
        - `:env` - map of environment variables
        - `:args` - extra arguments after the specifier
        - `:name` - GenServer name for registration
        - `:buffer_size` - (NIF backend only) max bytes to buffer per stdout line before
          flushing; range `[0, 100_000]`, default: `0` (unbuffered)
      """
      @spec start_link(keyword()) :: GenServer.on_start()
      def start_link(opts) do
        gen_opts = Keyword.take(opts, [:name])
        GenServer.start_link(__MODULE__, opts, gen_opts)
      end

      @doc """
      Send data to stdin of the running process.

      A newline (`\\n`) is automatically appended if `data` does not
      already end with one.

      Returns `:ok` on success, or `{:error, :closed}` if the process
      has already exited.
      """
      @spec send(GenServer.server(), String.t()) :: :ok | {:error, term()}
      def send(server, data) do
        GenServer.call(server, {:send, data})
      end

      @doc """
      Receive the next line from stdout.

      ## Options
        - `:timeout` - milliseconds to wait (default: 5000)
      """
      @spec recv(GenServer.server(), keyword()) ::
              {:ok, String.t()} | {:error, :timeout | :closed}
      def recv(server, opts \\ []) do
        timeout = Keyword.get(opts, :timeout, 5000)
        # Add a generous buffer so the GenServer always replies (via its internal
        # timer) before the outer GenServer.call times out, ensuring stale waiters
        # are never left in recv_waiters.
        GenServer.call(server, {:recv, timeout}, timeout + 1000)
      end

      @doc """
      Subscribe the calling process to stdout messages.

      After subscribing, the calling process will receive:

        - `{:denox_run_stdout, server_pid, line}` for each stdout line
        - `{:denox_run_exit, server_pid, exit_status}` when the process exits

      If the subscribing process dies, it is automatically removed from the
      subscriber list without needing an explicit `unsubscribe/1` call.
      """
      @spec subscribe(GenServer.server()) :: :ok
      def subscribe(server) do
        GenServer.call(server, {:subscribe, self()})
      end

      @doc """
      Unsubscribe from stdout messages.

      The calling process will stop receiving `{:denox_run_stdout, ...}` and
      `{:denox_run_exit, ...}` messages from this server.
      """
      @spec unsubscribe(GenServer.server()) :: :ok
      def unsubscribe(server) do
        GenServer.call(server, {:unsubscribe, self()})
      end

      @doc "Check if the runtime is still running."
      @spec alive?(GenServer.server()) :: boolean()
      def alive?(server) do
        GenServer.call(server, :alive?)
      end

      @doc """
      Return the OS PID of the process, if available.

      Returns `{:ok, pid}` for CLI-backed runtimes or `{:error, :not_available}`
      for NIF-backed runtimes where no separate OS process exists.
      """
      @spec os_pid(GenServer.server()) ::
              {:ok, non_neg_integer()} | {:error, :not_available | :not_running}
      def os_pid(server) do
        GenServer.call(server, :os_pid)
      end

      @doc "Stop the runtime."
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

        case init_backend(opts) do
          {:ok, backend_state} ->
            state = %__MODULE__{
              backend_state: backend_state,
              package: package,
              file: file
            }

            :telemetry.execute(
              [:denox, :run, :start],
              %{system_time: System.system_time()},
              %{package: package, file: file, backend: @backend_type}
            )

            {:ok, state}

          {:error, reason} ->
            {:stop, reason}
        end
      end

      @impl true
      def handle_call(msg, from, state) do
        Denox.Run.Base.__handle_call__(__MODULE__, msg, from, state)
      end

      @impl true
      def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
        # Remove subscriber with this monitor ref
        subscribers = Enum.reject(state.subscribers, fn {_p, sref} -> sref == ref end)

        # Remove any recv_waiters with this monitor ref, cancelling their timers to
        # suppress stale :recv_timeout messages (4-tuple: {from, mon_ref, timeout_ref, timer_ref}).
        waiters =
          :queue.filter(
            fn {_from, wref, _tref, timer_ref} ->
              if wref == ref, do: Process.cancel_timer(timer_ref)
              wref != ref
            end,
            state.recv_waiters
          )

        {:noreply, %{state | subscribers: subscribers, recv_waiters: waiters}}
      end

      def handle_info({:recv_timeout, timeout_ref}, state) do
        Denox.Run.Base.__handle_recv_timeout__(timeout_ref, state)
      end

      def handle_info(_msg, state) do
        {:noreply, state}
      end

      @impl true
      def terminate(_reason, %{exit_status: nil} = state) do
        stop_backend(state.backend_state)
        :ok
      end

      def terminate(_reason, _state), do: :ok

      # --- Shared dispatch helpers ---

      @doc false
      def dispatch_line(line, state) do
        :telemetry.execute(
          [:denox, :run, :recv],
          %{system_time: System.system_time()},
          %{line_bytes: byte_size(line), backend: @backend_type}
        )

        for {pid, _ref} <- state.subscribers do
          Kernel.send(pid, {:denox_run_stdout, self(), line})
        end

        case :queue.out(state.recv_waiters) do
          {{:value, {from, mon_ref, _tref, timer_ref}}, rest} ->
            Process.cancel_timer(timer_ref)
            Process.demonitor(mon_ref, [:flush])
            GenServer.reply(from, {:ok, line})
            %{state | recv_waiters: rest}

          {:empty, _} ->
            %{state | stdout_buffer: :queue.in(line, state.stdout_buffer)}
        end
      end

      @doc false
      def handle_exit(status, state) do
        state = %{state | exit_status: status}

        for {pid, _ref} <- state.subscribers do
          Kernel.send(pid, {:denox_run_exit, self(), status})
        end

        state = drain_waiters(state)

        :telemetry.execute(
          [:denox, :run, :stop],
          %{system_time: System.system_time()},
          %{
            package: state.package,
            file: state.file,
            exit_status: status,
            backend: @backend_type
          }
        )

        state
      end

      defp drain_waiters(state) do
        case :queue.out(state.recv_waiters) do
          {{:value, {from, mon_ref, _tref, timer_ref}}, rest} ->
            Process.cancel_timer(timer_ref)
            Process.demonitor(mon_ref, [:flush])
            GenServer.reply(from, {:error, :closed})
            drain_waiters(%{state | recv_waiters: rest})

          {:empty, _} ->
            state
        end
      end

      defoverridable handle_call: 3, handle_info: 2, terminate: 2
    end
  end

  # Shared handle_call implementation, called from the using module.
  # This avoids the deprecated `super` pattern.
  @doc false
  def __handle_call__(_module, {:send, data}, _from, %{exit_status: nil} = state) do
    data = if String.ends_with?(data, "\n"), do: data, else: data <> "\n"
    result = state.__struct__.send_backend(state.backend_state, data)
    {:reply, result, state}
  end

  def __handle_call__(_module, {:send, _data}, _from, state) do
    {:reply, {:error, :closed}, state}
  end

  def __handle_call__(_module, {:recv, timeout}, from, %{stdout_buffer: buffer} = state) do
    case :queue.out(buffer) do
      {{:value, line}, rest} ->
        {:reply, {:ok, line}, %{state | stdout_buffer: rest}}

      {:empty, _} ->
        if state.exit_status != nil do
          {:reply, {:error, :closed}, state}
        else
          {pid, _tag} = from
          mon_ref = Process.monitor(pid)
          timeout_ref = make_ref()
          timer_ref = Process.send_after(self(), {:recv_timeout, timeout_ref}, timeout)
          waiters = :queue.in({from, mon_ref, timeout_ref, timer_ref}, state.recv_waiters)
          {:noreply, %{state | recv_waiters: waiters}}
        end
    end
  end

  def __handle_call__(_module, {:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: [{pid, ref} | state.subscribers]}}
  end

  def __handle_call__(_module, {:unsubscribe, pid}, _from, state) do
    {removed, kept} = Enum.split_with(state.subscribers, fn {p, _ref} -> p == pid end)
    Enum.each(removed, fn {_p, ref} -> Process.demonitor(ref, [:flush]) end)
    {:reply, :ok, %{state | subscribers: kept}}
  end

  def __handle_call__(module, :alive?, _from, state) do
    alive = state.exit_status == nil and module.alive_backend?(state.backend_state)
    {:reply, alive, state}
  end

  def __handle_call__(
        _module,
        :os_pid,
        _from,
        %{backend_state: %{os_pid: os_pid}, exit_status: nil} = state
      ) do
    {:reply, {:ok, os_pid}, state}
  end

  def __handle_call__(_module, :os_pid, _from, %{exit_status: status} = state)
      when not is_nil(status) do
    {:reply, {:error, :not_running}, state}
  end

  # Backend without os_pid (e.g., NIF-backed Denox.Run)
  def __handle_call__(_module, :os_pid, _from, state) do
    {:reply, {:error, :not_available}, state}
  end

  def __handle_call__(_module, msg, _from, state) do
    {:reply, {:error, {:unknown_call, msg}}, state}
  end

  @doc false
  def __handle_recv_timeout__(timeout_ref, state) do
    # Find the waiter with this timeout_ref and reply :timeout, removing it.
    # If not found, the line already arrived and consumed the waiter — do nothing.
    waiter_list = :queue.to_list(state.recv_waiters)

    {matching, rest} =
      Enum.split_with(waiter_list, fn {_from, _mref, tref, _tref2} -> tref == timeout_ref end)

    case matching do
      [] ->
        {:noreply, state}

      [{from, mon_ref, _tref, _timer_ref} | _] ->
        Process.demonitor(mon_ref, [:flush])
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | recv_waiters: :queue.from_list(rest)}}
    end
  end
end
