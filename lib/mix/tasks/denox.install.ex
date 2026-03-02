defmodule Mix.Tasks.Denox.Install do
  @shortdoc "Install dependencies from deno.json"
  @moduledoc """
  Installs all dependencies declared in `deno.json`.

      $ mix denox.install

  This runs `deno install` with vendor mode enabled, creating
  `node_modules/` for npm packages in the deno.json directory.

  ## Options

    - `--config` - path to deno.json (default: "deno.json")
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [config: :string],
        aliases: [c: :config]
      )

    Mix.shell().info("Installing Denox dependencies...")

    case Denox.Deps.install(opts) do
      :ok ->
        Mix.shell().info("Dependencies installed successfully.")

      {:error, msg} ->
        Mix.raise(msg)
    end
  end
end

defmodule Mix.Tasks.Denox.Add do
  @shortdoc "Add a dependency to deno.json and reinstall"
  @moduledoc """
  Adds a dependency to `deno.json` and reinstalls.

      $ mix denox.add zod npm:zod@^3.22
      $ mix denox.add @std/path jsr:@std/path@^1.0
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        switches: [config: :string],
        aliases: [c: :config]
      )

    case positional do
      [name, specifier] ->
        Mix.shell().info("Adding #{name} (#{specifier})...")

        case Denox.Deps.add(name, specifier, opts) do
          :ok -> Mix.shell().info("Added #{name} successfully.")
          {:error, msg} -> Mix.raise(msg)
        end

      _ ->
        Mix.raise("Usage: mix denox.add <name> <specifier>")
    end
  end
end

defmodule Mix.Tasks.Denox.Remove do
  @shortdoc "Remove a dependency from deno.json and reinstall"
  @moduledoc """
  Removes a dependency from `deno.json` and reinstalls.

      $ mix denox.remove zod
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        switches: [config: :string],
        aliases: [c: :config]
      )

    case positional do
      [name] ->
        Mix.shell().info("Removing #{name}...")

        case Denox.Deps.remove(name, opts) do
          :ok -> Mix.shell().info("Removed #{name} successfully.")
          {:error, msg} -> Mix.raise(msg)
        end

      _ ->
        Mix.raise("Usage: mix denox.remove <name>")
    end
  end
end
