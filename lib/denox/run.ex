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

  use Denox.Run.Base, backend: :nif

  # --- Backend callbacks ---

  @impl Denox.Run.Base
  def init_backend(opts) do
    package = Keyword.get(opts, :package)
    file = Keyword.get(opts, :file)
    specifier = package || file
    permissions = Keyword.get(opts, :permissions)
    env = Keyword.get(opts, :env, %{})
    args = Keyword.get(opts, :args, [])
    buffer_size = Keyword.get(opts, :buffer_size, 0)

    permissions_json = build_permissions_json(permissions)

    env_vars_json =
      env
      |> Enum.into(%{}, fn {k, v} -> {to_string(k), to_string(v)} end)
      |> JSON.encode!()

    args_json = JSON.encode!(args)

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
      :ok -> :ok
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

  defp build_permissions_json(:all), do: JSON.encode!(%{"mode" => "allow_all"})
  defp build_permissions_json(nil), do: JSON.encode!(%{"mode" => "deny_all"})

  defp build_permissions_json(perms) when is_list(perms) do
    granular =
      Enum.reduce(perms, %{"mode" => "granular"}, fn
        {key, true}, acc -> Map.put(acc, Atom.to_string(key), true)
        {key, values}, acc when is_list(values) -> Map.put(acc, Atom.to_string(key), values)
        {_key, false}, acc -> acc
      end)

    JSON.encode!(granular)
  end
end
