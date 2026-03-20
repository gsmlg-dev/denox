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
             _ = Logger.info("Downloading Deno #{version} for #{target_name(target)}..."),
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

  defp download(url), do: download(url, 5)

  defp download(_url, 0), do: {:error, "Too many redirects"}

  defp download(url, redirects_left) do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    # Configure SSL with system CA certs and timeout
    ssl_opts = [
      timeout: 60_000,
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

    result =
      try do
        :httpc.request(:get, {url_charlist, []}, ssl_opts, body_format: :binary)
      rescue
        e -> {:error, Exception.message(e)}
      catch
        :exit, reason -> {:error, {:exit, reason}}
      end

    handle_response(result, redirects_left)
  end

  defp handle_response({:ok, {{_, status, _}, headers, _}}, redirects_left)
       when status in [301, 302, 303, 307, 308] do
    case Enum.find(headers, fn {k, _} -> String.downcase(to_string(k)) == "location" end) do
      {_, location} -> download(to_string(location), redirects_left - 1)
      nil -> {:error, "Redirect (HTTP #{status}) without Location header"}
    end
  end

  defp handle_response({:ok, {{_, 200, _}, _, body}}, _redirects_left), do: {:ok, body}

  defp handle_response({:ok, {{_, status, _}, _, body}}, _redirects_left) do
    {:error, "Download failed (HTTP #{status}): #{body}"}
  end

  defp handle_response({:error, reason}, _redirects_left) do
    {:error, "Download failed: #{inspect(reason)}"}
  end

  defp target_name({os, arch}) do
    os_name =
      case os do
        :macos -> "macOS"
        :linux -> "Linux"
      end

    "#{os_name} #{arch}"
  end

  defp extract_and_install(zip_data, dest) do
    dest_dir = Path.dirname(dest)

    with :ok <- File.mkdir_p(dest_dir),
         {:ok, files} <- safe_unzip(zip_data),
         {:ok, binary} <- find_deno_in_zip(files),
         :ok <- File.write(dest, binary),
         :ok <- File.chmod(dest, 0o755) do
      :ok
    else
      {:error, reason} -> {:error, "Failed to install deno binary: #{inspect(reason)}"}
    end
  end

  defp safe_unzip(zip_data) do
    case :zip.unzip(zip_data, [:memory]) do
      {:ok, files} -> {:ok, files}
      {:error, reason} -> {:error, {:unzip, reason}}
    end
  end

  defp find_deno_in_zip(files) do
    case List.keyfind(files, ~c"deno", 0) do
      {_name, binary} -> {:ok, binary}
      nil -> {:error, :deno_not_found_in_zip}
    end
  end
end
