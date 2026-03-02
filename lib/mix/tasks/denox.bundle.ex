defmodule Mix.Tasks.Denox.Bundle do
  @shortdoc "Bundle an npm/jsr package into a single JS file"
  @moduledoc """
  Bundles an npm/jsr package into a self-contained JavaScript file
  using `deno bundle`.

      $ mix denox.bundle npm:zod@3.22 priv/bundles/zod.js
      $ mix denox.bundle npm:lodash-es@4.17 priv/bundles/lodash.js --minify

  ## Options

    - `--config` - path to deno.json for import map resolution
    - `--platform` - target platform: "deno" (default) or "browser"
    - `--minify` - minify the output
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        switches: [config: :string, platform: :string, minify: :boolean],
        aliases: [c: :config, o: :output, m: :minify]
      )

    case positional do
      [specifier, output] ->
        Mix.shell().info("Bundling #{specifier} → #{output}...")

        case Denox.Npm.bundle(specifier, output, opts) do
          :ok -> Mix.shell().info("Bundle created successfully.")
          {:error, msg} -> Mix.raise(msg)
        end

      _ ->
        Mix.raise("Usage: mix denox.bundle <specifier> <output_path>")
    end
  end
end
