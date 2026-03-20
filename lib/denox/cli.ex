defmodule Denox.CLI do
  @moduledoc """
  Manages a bundled Deno CLI binary.

  Disabled by default. Enable by setting the version in config:

      config :denox, :cli, version: "2.1.4"

  The binary is downloaded from GitHub releases and cached in
  `_build/denox_cli-{version}/deno`.
  """

  require Logger

  @doc """
  Path to the cached deno binary. Downloads if needed.

  Returns `{:ok, path}` or `{:error, reason}`.
  """
  @spec bin_path() :: {:ok, String.t()} | {:error, term()}
  def bin_path do
    case configured_version() do
      nil -> {:error, :not_configured}
      version -> fetch_or_install(cache_path(version))
    end
  end

  defp fetch_or_install(path) do
    if File.exists?(path) do
      {:ok, path}
    else
      case install() do
        :ok -> {:ok, path}
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  Download the configured deno version for this platform.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec install() :: :ok | {:error, term()}
  def install do
    case configured_version() do
      nil ->
        {:error, :not_configured}

      version ->
        with {:ok, target} <- detect_target(),
             url = download_url(version, target),
             dest = cache_path(version),
             _ = Logger.info("Downloading Deno #{version} for #{target}..."),
             {:ok, zip_data} <- download(url),
             :ok <- extract_and_install(zip_data, dest) do
          Logger.info("Deno #{version} installed to #{dest}")
          :ok
        end
    end
  end

  @doc """
  Check if the binary is already downloaded.
  """
  @spec installed?() :: boolean()
  def installed? do
    case configured_version() do
      nil -> false
      version -> File.exists?(cache_path(version))
    end
  end

  @doc """
  The configured deno version, or nil if not configured.
  """
  @spec configured_version() :: String.t() | nil
  def configured_version do
    case Application.get_env(:denox, :cli) do
      nil -> nil
      config -> Keyword.get(config, :version)
    end
  end

  # --- Private ---

  defp cache_path(version) do
    Path.join(["_build", "denox_cli-#{version}", "deno"])
  end

  defp detect_target do
    with {:ok, os} <- detect_os(),
         {:ok, arch} <- detect_arch() do
      {:ok, {os, arch}}
    end
  end

  defp detect_os do
    case :os.type() do
      {:unix, :darwin} -> {:ok, :macos}
      {:unix, :linux} -> {:ok, :linux}
      {_, os} -> {:error, "Unsupported OS: #{os}"}
    end
  end

  defp detect_arch do
    arch =
      :erlang.system_info(:system_architecture)
      |> to_string()

    cond do
      arch =~ "x86_64" or arch =~ "amd64" -> {:ok, :x86_64}
      arch =~ "aarch64" or arch =~ "arm64" -> {:ok, :aarch64}
      true -> {:error, "Unsupported architecture: #{arch}"}
    end
  end

  defp download_url(version, {os, arch}) do
    target =
      case {os, arch} do
        {:macos, :x86_64} -> "x86_64-apple-darwin"
        {:macos, :aarch64} -> "aarch64-apple-darwin"
        {:linux, :x86_64} -> "x86_64-unknown-linux-gnu"
        {:linux, :aarch64} -> "aarch64-unknown-linux-gnu"
      end

    "https://github.com/denoland/deno/releases/download/v#{version}/deno-#{target}.zip"
  end

  defp download(url) do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    # Configure SSL with system CA certs
    ssl_opts = [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]

    url_charlist = String.to_charlist(url)

    case :httpc.request(:get, {url_charlist, []}, ssl_opts, body_format: :binary) do
      {:ok, {{_, 302, _}, headers, _}} ->
        location =
          headers
          |> Enum.find(fn {k, _} -> String.downcase(to_string(k)) == "location" end)
          |> elem(1)
          |> to_string()

        download(location)

      {:ok, {{_, 200, _}, _, body}} ->
        {:ok, body}

      {:ok, {{_, status, _}, _, body}} ->
        {:error, "Download failed (HTTP #{status}): #{body}"}

      {:error, reason} ->
        {:error, "Download failed: #{inspect(reason)}"}
    end
  end

  defp extract_and_install(zip_data, dest) do
    dest_dir = Path.dirname(dest)
    File.mkdir_p!(dest_dir)

    case :zip.unzip(zip_data, [:memory]) do
      {:ok, files} ->
        case List.keyfind(files, ~c"deno", 0) do
          {_name, binary} ->
            File.write!(dest, binary)
            File.chmod!(dest, 0o755)
            :ok

          nil ->
            {:error, "deno binary not found in zip archive"}
        end

      {:error, reason} ->
        {:error, "Failed to extract zip: #{inspect(reason)}"}
    end
  end
end
