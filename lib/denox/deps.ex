defmodule Denox.Deps do
  @moduledoc """
  Dependency management for Denox using the `deno` CLI at build-time.

  Manages npm/jsr packages declared in `deno.json` via `deno install`.
  In Deno 2.x, vendoring is handled by setting `"vendor": true` in
  deno.json and running `deno install`, which creates `node_modules/`
  for npm packages in the same directory as deno.json.

  The `deno` CLI is only required at build-time, not at runtime.

  ## Workflow

      # 1. Declare deps in deno.json
      # 2. Install deps
      Denox.Deps.install()

      # 3. Create a runtime with installed deps
      {:ok, rt} = Denox.Deps.runtime()

      # 4. Use bare specifier imports
      Denox.eval_async(rt, ~s[
        const { z } = await import("zod");
        return z.string().parse("hello");
      ]) |> Task.await()
  """

  @cache_dir "_denox/cache"
  @deno_json "deno.json"

  @doc """
  Install all dependencies declared in `deno.json`.

  Sets `"vendor": true` in the config and runs `deno install`,
  which creates `node_modules/` for npm packages in the config directory.

  Options:
    - `:config` - path to deno.json (default: "deno.json")

  Returns `:ok` or `{:error, message}`.
  """
  def install(opts \\ []) do
    config = Keyword.get(opts, :config, @deno_json)

    with :ok <- check_deno(),
         :ok <- check_config(config),
         :ok <- ensure_vendor_config(config),
         :ok <- run_deno_install(config) do
      :ok
    end
  end

  @doc """
  Create a runtime configured to load from the installed deps directory.

  Options:
    - `:config` - path to deno.json (default: "deno.json")
    - `:cache_dir` - cache directory for remote fetches (default: "_denox/cache")
    - `:import_map` - map of bare specifiers to resolved URLs/paths
    - Additional options passed to `Denox.runtime/1`

  Returns `{:ok, runtime}` or `{:error, message}`.
  """
  def runtime(opts \\ []) do
    config = Keyword.get(opts, :config, @deno_json)
    cache_dir = Keyword.get(opts, :cache_dir, @cache_dir)
    import_map = Keyword.get(opts, :import_map, %{})
    config_dir = config |> Path.expand() |> Path.dirname()

    case check(config: config) do
      :ok ->
        runtime_opts = [
          base_dir: config_dir,
          cache_dir: cache_dir
        ]

        runtime_opts =
          if map_size(import_map) > 0,
            do: Keyword.put(runtime_opts, :import_map, import_map),
            else: runtime_opts

        Denox.runtime(runtime_opts)

      error ->
        error
    end
  end

  @doc """
  Add a dependency to deno.json and reinstall.

  ## Examples

      Denox.Deps.add("zod", "npm:zod@^3.22")
      Denox.Deps.add("@std/path", "jsr:@std/path@^1.0")
  """
  def add(name, specifier, opts \\ []) do
    config = Keyword.get(opts, :config, @deno_json)

    with :ok <- check_deno(),
         :ok <- ensure_config(config),
         :ok <- add_to_config(config, name, specifier) do
      install(opts)
    end
  end

  @doc """
  Remove a dependency from deno.json and reinstall.
  """
  def remove(name, opts \\ []) do
    config = Keyword.get(opts, :config, @deno_json)

    with :ok <- check_deno(),
         :ok <- check_config(config),
         :ok <- remove_from_config(config, name) do
      install(opts)
    end
  end

  @doc """
  List dependencies declared in deno.json.

  Returns `{:ok, %{name => specifier}}` or `{:error, message}`.
  """
  def list(opts \\ []) do
    config = Keyword.get(opts, :config, @deno_json)

    with :ok <- check_config(config) do
      case File.read(config) do
        {:ok, content} ->
          case Denox.JSON.decode(content) do
            {:ok, %{"imports" => imports}} when is_map(imports) ->
              {:ok, imports}

            {:ok, _} ->
              {:ok, %{}}

            {:error, _} ->
              {:error, "Failed to parse #{config}"}
          end

        {:error, reason} ->
          {:error, "Failed to read #{config}: #{reason}"}
      end
    end
  end

  @doc """
  Check if dependencies have been installed.

  Looks for `node_modules/` in the config directory as evidence
  that `deno install` has been run.

  Options:
    - `:config` - path to deno.json (default: "deno.json")
    - `:vendor_dir` - legacy option, checks if this directory exists

  Returns `:ok` or `{:error, message}`.
  """
  def check(opts \\ []) do
    # Support legacy vendor_dir option for backwards compatibility
    if vendor_dir = Keyword.get(opts, :vendor_dir) do
      if File.dir?(vendor_dir) do
        :ok
      else
        {:error,
         "Vendor directory '#{vendor_dir}' not found. Run Denox.Deps.install() or `mix denox.install` first."}
      end
    else
      config = Keyword.get(opts, :config, @deno_json)
      config_dir = config |> Path.expand() |> Path.dirname()
      node_modules = Path.join(config_dir, "node_modules")

      if File.dir?(node_modules) do
        :ok
      else
        {:error,
         "Dependencies not installed (node_modules not found in #{config_dir}). " <>
           "Run Denox.Deps.install() or `mix denox.install` first."}
      end
    end
  end

  # --- Private helpers ---

  defp check_deno do
    case System.find_executable("deno") do
      nil -> {:error, "deno CLI not found in PATH. Install from https://deno.land"}
      _ -> :ok
    end
  end

  defp check_config(config) do
    if File.exists?(config) do
      :ok
    else
      {:error, "#{config} not found"}
    end
  end

  defp ensure_config(config) do
    if File.exists?(config) do
      :ok
    else
      File.write(config, Denox.JSON.encode_pretty!(%{"imports" => %{}}))
    end
  end

  defp ensure_vendor_config(config) do
    with {:ok, content} <- File.read(config),
         {:ok, json} <- Denox.JSON.decode(content) do
      unless Map.get(json, "vendor") == true do
        updated = Map.put(json, "vendor", true)
        File.write!(config, Denox.JSON.encode_pretty!(updated))
      end

      :ok
    else
      _ -> {:error, "Failed to update #{config}"}
    end
  end

  defp run_deno_install(config) do
    config_dir = config |> Path.expand() |> Path.dirname()

    case System.cmd("deno", ["install"], cd: config_dir, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, "deno install failed: #{output}"}
    end
  end

  defp add_to_config(config, name, specifier) do
    with {:ok, content} <- File.read(config),
         {:ok, json} <- Denox.JSON.decode(content) do
      imports = Map.get(json, "imports", %{})
      updated = Map.put(json, "imports", Map.put(imports, name, specifier))
      File.write(config, Denox.JSON.encode_pretty!(updated))
    else
      _ -> {:error, "Failed to update #{config}"}
    end
  end

  defp remove_from_config(config, name) do
    with {:ok, content} <- File.read(config),
         {:ok, json} <- Denox.JSON.decode(content) do
      imports = Map.get(json, "imports", %{})
      updated = Map.put(json, "imports", Map.delete(imports, name))
      File.write(config, Denox.JSON.encode_pretty!(updated))
    else
      _ -> {:error, "Failed to update #{config}"}
    end
  end
end
