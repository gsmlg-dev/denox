defmodule Denox.CLI.Run do
  @moduledoc """
  Run Deno programs as managed subprocesses using the bundled CLI.

  Same API as `Denox.Run`, but uses the bundled binary from `Denox.CLI`
  instead of the NIF runtime. Primarily useful for testing or when
  full CLI features (deno fmt, deno lint) are needed.

  ## Examples

      {:ok, pid} = Denox.CLI.Run.start_link(
        package: "@modelcontextprotocol/server-github",
        permissions: :all,
        env: %{"GITHUB_PERSONAL_ACCESS_TOKEN" => token}
      )

      :ok = Denox.CLI.Run.send(pid, data)
      {:ok, line} = Denox.CLI.Run.recv(pid, timeout: 5000)

  ## Telemetry Events

  Denox.CLI.Run emits the following telemetry events:

    * `[:denox, :run, :start]` — emitted when the runtime starts
      * Measurements: `%{system_time: integer}`
      * Metadata: `%{package: string | nil, file: string | nil, backend: :cli}`

    * `[:denox, :run, :stop]` — emitted when the runtime exits
      * Measurements: `%{system_time: integer}`
      * Metadata: `%{package: string | nil, file: string | nil, exit_status: integer, backend: :cli}`

    * `[:denox, :run, :recv]` — emitted for each stdout line received
      * Measurements: `%{system_time: integer}`
      * Metadata: `%{line_bytes: integer, backend: :cli}`
  """

  use Denox.Run.Base, backend: :cli

  # --- Backend callbacks ---

  @impl Denox.Run.Base
  def init_backend(opts) do
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

        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, pid} -> pid
            nil -> 0
          end

        {:ok, %{port: port, os_pid: os_pid}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Denox.Run.Base
  def send_backend(%{port: port}, data) do
    Port.command(port, data)
    :ok
  rescue
    ArgumentError -> {:error, :closed}
  end

  @impl Denox.Run.Base
  def stop_backend(%{port: port}) do
    Port.close(port)
    :ok
  end

  @impl Denox.Run.Base
  def alive_backend?(%{port: port}) do
    Port.info(port) != nil
  end

  # --- Port message handling ---

  @impl GenServer
  def handle_info({port, {:data, {:eol, line}}}, %{backend_state: %{port: port}} = state) do
    state = dispatch_line(line, state)
    {:noreply, state}
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{backend_state: %{port: port}} = state) do
    state = dispatch_line(chunk, state)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{backend_state: %{port: port}} = state) do
    state = handle_exit(status, state)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    super(msg, state)
  end

  # --- Private ---

  defp find_deno do
    case Denox.CLI.bin_path() do
      {:ok, path} ->
        {:ok, path}

      {:error, _} ->
        {:error,
         "Deno CLI not configured. Add `config :denox, :cli, version: \"2.x.x\"` and run `mix denox.cli.install`"}
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
  # nil and :none both mean "no explicit allow flags" (Deno denies by default in v2)
  defp permissions_to_args(nil), do: []
  defp permissions_to_args(:none), do: []

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
    |> Enum.map(fn {k, v} -> {env_to_charlist(k), env_to_charlist(v)} end)
  end

  defp env_to_charlist(value) when is_atom(value), do: Atom.to_charlist(value)
  defp env_to_charlist(value) when is_binary(value), do: String.to_charlist(value)

  defp env_to_charlist(value),
    do: raise(ArgumentError, "env values must be atoms or binaries, got: #{inspect(value)}")
end
