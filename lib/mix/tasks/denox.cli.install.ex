defmodule Mix.Tasks.Denox.Cli.Install do
  @shortdoc "Download the configured Deno CLI binary"
  @moduledoc """
  Downloads the Deno CLI binary for the current platform.

      $ mix denox.cli.install

  The version is read from config:

      config :denox, :cli, version: "2.1.4"

  The binary is cached at `_build/denox_cli-{version}/deno`.
  """

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.config")

    version = Denox.CLI.configured_version()

    unless version do
      Mix.raise("""
      No Deno CLI version configured.

      Add to your config:

          config :denox, :cli, version: "2.1.4"
      """)
    end

    if Denox.CLI.installed?() do
      Mix.shell().info("Deno #{version} is already installed.")
    else
      case Denox.CLI.install() do
        :ok -> Mix.shell().info("Deno #{version} installed successfully.")
        {:error, reason} -> Mix.raise("Failed to install Deno: #{inspect(reason)}")
      end
    end
  end
end
