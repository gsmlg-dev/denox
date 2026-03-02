defmodule Denox.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/gsmlg-dev/denox"

  def project do
    [
      app: :denox,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package()
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
        "LICENSE"
      ],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp deps do
    [
      {:rustler, "~> 0.36", optional: true},
      {:rustler_precompiled, "~> 0.8"},
      {:jason, "~> 1.4"}
    ]
  end
end
