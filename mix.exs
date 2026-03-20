defmodule Denox.MixProject do
  use Mix.Project

  @version "0.5.0"
  @source_url "https://github.com/gsmlg-dev/denox"

  def project do
    [
      app: :denox,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      dialyzer: [
        plt_add_apps: [:mix]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp description do
    "Embed the Deno TypeScript/JavaScript runtime in Elixir via a Rustler NIF."
  end

  defp package do
    [
      files: [
        "lib",
        "native/denox_nif/src",
        "native/denox_nif/Cargo.toml",
        "native/denox_nif/Cargo.lock",
        "checksum-*.exs",
        ".formatter.exs",
        "mix.exs",
        "README.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md", "DENOX_DESIGN.md"],
      groups_for_modules: [
        Core: [Denox, Denox.CallbackHandler],
        Pool: [Denox.Pool],
        Runner: [Denox.Run, Denox.CLI.Run],
        CLI: [Denox.CLI],
        Dependencies: [Denox.Deps, Denox.Npm],
        Internal: [Denox.Native, Denox.Run.Base]
      ]
    ]
  end

  defp deps do
    [
      {:rustler, "~> 0.36", optional: true},
      {:rustler_precompiled, "~> 0.8"},
      {:jason, "~> 1.4", optional: true},
      {:telemetry, "~> 1.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:benchee, "~> 1.0", only: :dev, runtime: false}
    ]
  end
end
