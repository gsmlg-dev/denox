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
      """
      @spec start_link(keyword()) :: GenServer.on_start()
      def start_link(opts) do
        gen_opts = Keyword.take(opts, [:name])
        GenServer.start_link(__MODULE__, opts, gen_opts)
      end

      @doc "Send a line to stdin."
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
        GenServer.call(server, :recv, timeout)
      catch
        :exit, {:timeout, _} -> {:error, :timeout}
      end

      @doc "Subscribe the calling process to stdout messages."
      @spec subscribe(GenServer.server()) :: :ok
      def subscribe(server) do
        GenServer.call(server, {:subscribe, self()})
      end

      @doc "Unsubscribe from stdout messages."
      @spec unsubscribe(GenServer.server()) :: :ok
      def unsubscribe(server) do
        GenServer.call(server, {:unsubscribe, self()})
      end

      @doc "Check if the runtime is still running."
      @spec alive?(GenServer.server()) :: boolean()
      def alive?(server) do
        GenServer.call(server, :alive?)
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
      def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
        # Remove from subscribers (monitor was set without storing ref)
        subscribers = List.delete(state.subscribers, pid)

        # Remove any recv_waiters from this pid (monitor ref stored in waiter tuple)
        waiters =
          :queue.filter(fn {_from, wref} -> wref != ref end, state.recv_waiters)

        {:noreply, %{state | subscribers: subscribers, recv_waiters: waiters}}
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

        for pid <- state.subscribers do
          Kernel.send(pid, {:denox_run_stdout, self(), line})
        end

        case :queue.out(state.recv_waiters) do
          {{:value, {from, ref}}, rest} ->
            Process.demonitor(ref, [:flush])
            GenServer.reply(from, {:ok, line})
            %{state | recv_waiters: rest}

          {:empty, _} ->
            %{state | stdout_buffer: :queue.in(line, state.stdout_buffer)}
        end
      end

      @doc false
      def handle_exit(status, state) do
        state = %{state | exit_status: status}

        for pid <- state.subscribers do
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
          {{:value, {from, ref}}, rest} ->
            Process.demonitor(ref, [:flush])
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

  def __handle_call__(_module, :recv, from, %{stdout_buffer: buffer} = state) do
    case :queue.out(buffer) do
      {{:value, line}, rest} ->
        {:reply, {:ok, line}, %{state | stdout_buffer: rest}}

      {:empty, _} ->
        if state.exit_status != nil do
          {:reply, {:error, :closed}, state}
        else
          {pid, _tag} = from
          ref = Process.monitor(pid)
          waiters = :queue.in({from, ref}, state.recv_waiters)
          {:noreply, %{state | recv_waiters: waiters}}
        end
    end
  end

  def __handle_call__(_module, {:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: [pid | state.subscribers]}}
  end

  def __handle_call__(_module, {:unsubscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: List.delete(state.subscribers, pid)}}
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

  def __handle_call__(_module, msg, _from, state) do
    {:reply, {:error, {:unknown_call, msg}}, state}
  end
end
