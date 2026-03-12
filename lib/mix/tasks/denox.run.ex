defmodule Mix.Tasks.Denox.Run do
  @shortdoc "Run a Deno package or script"
  @moduledoc """
  Runs a JSR/npm package or local script using the Deno runtime.

  This is a drop-in replacement for `deno run` that integrates with
  the Denox project configuration.

      $ mix denox.run -A @modelcontextprotocol/server-github
      $ mix denox.run --allow-net --allow-env=GITHUB_TOKEN npm:some-tool
      $ mix denox.run -A scripts/server.ts -- --port 3000

  ## Options

    - `-A` / `--allow-all` - grant all permissions
    - `--allow-net[=hosts]` - allow network access
    - `--allow-env[=vars]` - allow environment variable access
    - `--allow-read[=paths]` - allow file system read access
    - `--allow-write[=paths]` - allow file system write access
    - `--allow-run[=programs]` - allow running subprocesses
    - `--allow-ffi` - allow loading dynamic libraries
    - `--allow-sys` - allow system info access
    - `--allow-hrtime` - allow high-resolution time measurement

  Arguments after `--` are passed to the script.

  Stdin is forwarded to the subprocess, making this suitable for
  stdio-based servers (e.g. MCP servers using JSON-RPC over stdio).
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:telemetry)

    {deno_args, specifier, script_args} = parse_args(args)

    unless specifier do
      Mix.raise("Usage: mix denox.run [options] <package-or-file> [-- script-args...]")
    end

    deno =
      case System.find_executable("deno") do
        nil -> Mix.raise("deno CLI not found in PATH. Install from https://deno.land")
        path -> path
      end

    specifier = resolve_specifier(specifier)
    full_args = ["run"] ++ deno_args ++ [specifier] ++ script_args

    Mix.shell().info("Running: deno #{Enum.join(full_args, " ")}")

    port =
      Port.open({:spawn_executable, deno}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:args, full_args},
        {:line, 1_048_576}
      ])

    # Spawn a task to read from terminal stdin and forward to the port
    stdin_task = Task.async(fn -> stdin_loop(port) end)

    result = stdout_loop(port)

    Task.shutdown(stdin_task, :brutal_kill)
    result
  end

  defp stdout_loop(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        IO.puts(line)
        stdout_loop(port)

      {^port, {:data, {:noeol, chunk}}} ->
        IO.write(chunk)
        stdout_loop(port)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, status}} ->
        Mix.raise("deno process exited with status #{status}")
    end
  end

  defp stdin_loop(port) do
    case IO.read(:stdio, :line) do
      {:error, _} ->
        :ok

      :eof ->
        :ok

      data ->
        try do
          Port.command(port, data)
        rescue
          ArgumentError -> :ok
        end

        stdin_loop(port)
    end
  end

  defp parse_args(args) do
    {script_args, args} = split_on_double_dash(args)
    {deno_args, positional} = extract_flags(args, [], [])

    specifier = List.first(positional)
    {deno_args, specifier, script_args}
  end

  defp split_on_double_dash(args) do
    case Enum.split_while(args, &(&1 != "--")) do
      {before, ["--" | rest]} -> {rest, before}
      {before, []} -> {[], before}
    end
  end

  defp extract_flags([], flags, positional) do
    {Enum.reverse(flags), Enum.reverse(positional)}
  end

  defp extract_flags(["-A" | rest], flags, positional) do
    extract_flags(rest, ["-A" | flags], positional)
  end

  defp extract_flags(["--allow-all" | rest], flags, positional) do
    extract_flags(rest, ["-A" | flags], positional)
  end

  defp extract_flags(["--" <> _ = flag | rest], flags, positional) do
    extract_flags(rest, [flag | flags], positional)
  end

  defp extract_flags([arg | rest], flags, positional) do
    extract_flags(rest, flags, [arg | positional])
  end

  # Auto-prefix bare @scope/name with "npm:" since deno run requires it.
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
end
