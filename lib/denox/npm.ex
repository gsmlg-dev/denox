defmodule Denox.Npm do
  @moduledoc """
  Pre-bundling support for npm/jsr packages via `deno bundle`.

  For packages that don't vendor cleanly, bundle them into a self-contained
  JS file that can be loaded into any runtime.

  ## Workflow

      # 1. Bundle a package at build-time
      Denox.Npm.bundle!("npm:zod@3.22", "priv/bundles/zod.js")

      # 2. Load into a runtime
      {:ok, rt} = Denox.runtime()
      :ok = Denox.Npm.load(rt, "priv/bundles/zod.js")

      # 3. Use the package
      {:ok, result} = Denox.eval(rt, "globalThis.zod.string().parse('hello')")

  The `deno` CLI is only required at bundle-time, not at runtime.
  """

  @doc """
  Bundle an npm/jsr package into a single JavaScript file.

  Uses `deno bundle` to produce a self-contained JS file with all
  dependencies inlined. The output is an ES module.

  ## Options

    - `:config` - path to deno.json for import map resolution
    - `:platform` - target platform: "deno" (default) or "browser"
    - `:minify` - minify the output (default: false)

  Returns `:ok` or `{:error, message}`.

  ## Examples

      Denox.Npm.bundle("npm:zod@3.22", "priv/bundles/zod.js")
      Denox.Npm.bundle("npm:lodash-es@4.17", "priv/bundles/lodash.js", minify: true)
  """
  def bundle(specifier, output_path, opts \\ []) do
    with :ok <- check_deno() do
      File.mkdir_p!(Path.dirname(output_path))

      args = build_bundle_args(specifier, output_path, opts)

      case System.cmd("deno", args, stderr_to_stdout: true) do
        {_, 0} -> :ok
        {output, _} -> {:error, "deno bundle failed: #{output}"}
      end
    end
  end

  @doc """
  Bundle an npm/jsr package, raising on failure.

  Same as `bundle/3` but raises on error.
  """
  def bundle!(specifier, output_path, opts \\ []) do
    case bundle(specifier, output_path, opts) do
      :ok -> :ok
      {:error, msg} -> raise msg
    end
  end

  @doc """
  Load a bundled JavaScript file into a runtime.

  Evaluates the bundle file contents in the runtime, making the
  exported values available via `globalThis`.

  Returns `:ok` or `{:error, message}`.
  """
  def load(rt, bundle_path) do
    case File.read(bundle_path) do
      {:ok, code} ->
        Denox.exec(rt, code)

      {:error, reason} ->
        {:error, "Failed to read bundle #{bundle_path}: #{reason}"}
    end
  end

  @doc """
  Bundle from an entrypoint file rather than a specifier.

  Useful when you have a local .ts/.js entrypoint that imports
  multiple packages.

  ## Options

    Same as `bundle/3`.

  Returns `:ok` or `{:error, message}`.
  """
  def bundle_file(entrypoint, output_path, opts \\ []) do
    with :ok <- check_deno(),
         :ok <- check_entrypoint(entrypoint) do
      File.mkdir_p!(Path.dirname(output_path))
      args = build_bundle_args(entrypoint, output_path, opts)

      case System.cmd("deno", args, stderr_to_stdout: true) do
        {_, 0} -> :ok
        {output, _} -> {:error, "deno bundle failed: #{output}"}
      end
    end
  end

  # --- Private ---

  defp check_entrypoint(entrypoint) do
    if File.exists?(entrypoint) do
      :ok
    else
      {:error, "Entrypoint #{entrypoint} not found"}
    end
  end

  defp check_deno do
    case System.find_executable("deno") do
      nil -> {:error, "deno CLI not found in PATH. Install from https://deno.land"}
      _ -> :ok
    end
  end

  defp build_bundle_args(input, output, opts) do
    args = ["bundle", input, "-o", output]

    args =
      case Keyword.get(opts, :config) do
        nil -> args
        config -> args ++ ["--config", config]
      end

    args =
      case Keyword.get(opts, :platform) do
        nil -> args
        platform -> args ++ ["--platform", platform]
      end

    args =
      if Keyword.get(opts, :minify, false) do
        args ++ ["--minify"]
      else
        args
      end

    args
  end
end
