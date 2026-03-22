defmodule Denox.Run do
  @moduledoc """
  Run Deno programs as NIF-backed long-lived runtimes.

  Uses an in-process `deno_runtime` MainWorker (no external `deno` binary
  required) wrapped in a GenServer with bidirectional stdio and OTP supervision.

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

  ## Telemetry Events

  Denox.Run emits the following telemetry events:

    * `[:denox, :run, :start]` — emitted when the runtime starts
      * Measurements: `%{system_time: integer}`
      * Metadata: `%{package: string | nil, file: string | nil, backend: :nif}`

    * `[:denox, :run, :stop]` — emitted when the runtime exits
      * Measurements: `%{system_time: integer}`
      * Metadata: `%{package: string | nil, file: string | nil, exit_status: integer, backend: :nif}`

    * `[:denox, :run, :recv]` — emitted for each stdout line received
      * Measurements: `%{system_time: integer}`
      * Metadata: `%{line_bytes: integer, backend: :nif}`

  ## Environment Variables

  The `:env` option passes environment variables to the Deno runtime via
  `Deno.env.get()`. The variables are set in the OS process environment
  before the worker starts. **Note:** concurrent `Denox.Run` instances may
  see each other's env vars if started simultaneously. For strict isolation,
  use `Denox.CLI.Run` with a subprocess-per-instance model, or ensure env
  var names are unique across instances.
  """

  use Denox.Run.Base, backend: :nif

  # --- Backend callbacks ---

  @impl Denox.Run.Base
  def init_backend(opts) do
    package = Keyword.get(opts, :package)
    file = Keyword.get(opts, :file)
    specifier = resolve_specifier(package || file)
    permissions = Keyword.get(opts, :permissions)
    env = Keyword.get(opts, :env, %{})
    args = Keyword.get(opts, :args, [])
    buffer_size = opts |> Keyword.get(:buffer_size, 0) |> max(0) |> min(100_000)

    permissions_json = build_permissions_json(permissions)

    env_vars_json =
      env
      |> Enum.into(%{}, fn {k, v} -> {to_string(k), to_string(v)} end)
      |> Denox.JSON.encode!()

    args_json = Denox.JSON.encode!(args)

    case Denox.Native.runtime_run(
           specifier,
           permissions_json,
           env_vars_json,
           args_json,
           buffer_size
         ) do
      {:ok, resource} ->
        # Spawn a receiver task that loops runtime_run_recv on a dirty scheduler
        gen_server_pid = self()
        receiver_ref = make_ref()

        receiver_pid =
          spawn_link(fn ->
            receiver_loop(resource, gen_server_pid, receiver_ref)
          end)

        {:ok, %{resource: resource, receiver_pid: receiver_pid, receiver_ref: receiver_ref}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Denox.Run.Base
  def send_backend(%{resource: resource}, data) do
    case Denox.Native.runtime_run_send(resource, data) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @impl Denox.Run.Base
  def stop_backend(%{resource: resource, receiver_pid: receiver_pid}) do
    Denox.Native.runtime_run_stop(resource)
    Process.unlink(receiver_pid)
    Process.exit(receiver_pid, :shutdown)
    :ok
  end

  @impl Denox.Run.Base
  def alive_backend?(%{resource: resource}) do
    Denox.Native.runtime_run_alive(resource)
  end

  # --- Receiver messages ---

  @impl GenServer
  def handle_info({:denox_run_line, ref, line}, %{backend_state: %{receiver_ref: ref}} = state) do
    state = dispatch_line(line, state)
    {:noreply, state}
  end

  def handle_info(
        {:denox_run_closed, ref},
        %{backend_state: %{receiver_ref: ref}} = state
      ) do
    state = handle_exit(0, state)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    super(msg, state)
  end

  # --- Private ---

  defp receiver_loop(resource, gen_server_pid, ref) do
    case Denox.Native.runtime_run_recv(resource) do
      {:ok, nil} ->
        # Timeout or no data — check if still alive
        if Denox.Native.runtime_run_alive(resource) do
          receiver_loop(resource, gen_server_pid, ref)
        else
          Kernel.send(gen_server_pid, {:denox_run_closed, ref})
        end

      {:ok, line} ->
        Kernel.send(gen_server_pid, {:denox_run_line, ref, line})
        receiver_loop(resource, gen_server_pid, ref)

      {:error, _reason} ->
        Kernel.send(gen_server_pid, {:denox_run_closed, ref})
    end
  end

  defp resolve_specifier(spec) do
    cond do
      String.starts_with?(spec, ["npm:", "jsr:", "http://", "https://", "file://"]) -> spec
      String.starts_with?(spec, "@") -> "npm:#{spec}"
      true -> spec
    end
  end

  defp build_permissions_json(:all), do: Denox.JSON.encode!(%{"mode" => "allow_all"})
  # nil and :none both map to deny_all for backward compatibility
  defp build_permissions_json(nil), do: Denox.JSON.encode!(%{"mode" => "deny_all"})
  defp build_permissions_json(:none), do: Denox.JSON.encode!(%{"mode" => "deny_all"})

  defp build_permissions_json(perms) when is_list(perms) do
    granular =
      Enum.reduce(perms, %{"mode" => "granular"}, fn
        {key, true}, acc -> Map.put(acc, Atom.to_string(key), true)
        {key, values}, acc when is_list(values) -> Map.put(acc, Atom.to_string(key), values)
        {_key, false}, acc -> acc
      end)

    Denox.JSON.encode!(granular)
  end
end
