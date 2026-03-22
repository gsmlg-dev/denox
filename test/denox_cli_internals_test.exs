defmodule DenoxCLIInternalsTest do
  @moduledoc """
  Unit tests for Denox.CLI internal functions (zip extraction, response handling,
  platform detection, URL generation). These test @doc false functions directly
  to achieve coverage without network calls.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  describe "extract_and_install/2" do
    test "extracts deno binary from valid zip and writes to dest", %{tmp_dir: dir} do
      dest = Path.join(dir, "deno")
      zip_data = build_zip([{~c"deno", "fake-deno-binary-content"}])

      assert :ok = Denox.CLI.extract_and_install(zip_data, dest)
      assert File.exists?(dest)
      assert File.read!(dest) == "fake-deno-binary-content"

      # Verify executable permission
      %{mode: mode} = File.stat!(dest)
      assert Bitwise.band(mode, 0o755) == 0o755
    end

    test "returns error when zip has no deno entry", %{tmp_dir: dir} do
      dest = Path.join(dir, "deno")
      zip_data = build_zip([{~c"not-deno", "some content"}])

      assert {:error, msg} = Denox.CLI.extract_and_install(zip_data, dest)
      assert msg =~ "Failed to install"
    end

    test "returns error for invalid zip data", %{tmp_dir: dir} do
      dest = Path.join(dir, "deno")

      assert {:error, msg} = Denox.CLI.extract_and_install("not-a-zip", dest)
      assert msg =~ "Failed to install"
    end

    test "creates parent directories if they don't exist", %{tmp_dir: dir} do
      dest = Path.join([dir, "nested", "deep", "deno"])
      zip_data = build_zip([{~c"deno", "binary"}])

      assert :ok = Denox.CLI.extract_and_install(zip_data, dest)
      assert File.exists?(dest)
    end
  end

  describe "safe_unzip/1" do
    test "unzips valid zip data to memory" do
      zip_data = build_zip([{~c"deno", "content"}, {~c"README", "readme"}])

      assert {:ok, files} = Denox.CLI.safe_unzip(zip_data)
      assert length(files) == 2
      assert {~c"deno", "content"} in files
    end

    test "returns error for corrupt zip data" do
      assert {:error, {:unzip, _}} = Denox.CLI.safe_unzip("corrupt data")
    end
  end

  describe "find_deno_in_zip/1" do
    test "finds deno binary in file list" do
      files = [{~c"deno", "binary-data"}, {~c"LICENSE", "MIT"}]

      assert {:ok, "binary-data"} = Denox.CLI.find_deno_in_zip(files)
    end

    test "returns error when deno not in file list" do
      files = [{~c"LICENSE", "MIT"}, {~c"README", "docs"}]

      assert {:error, :deno_not_found_in_zip} = Denox.CLI.find_deno_in_zip(files)
    end

    test "returns error for empty file list" do
      assert {:error, :deno_not_found_in_zip} = Denox.CLI.find_deno_in_zip([])
    end
  end

  describe "handle_response/2" do
    test "returns body for 200 response" do
      response = {:ok, {{"HTTP/1.1", 200, "OK"}, [], "zip-data"}}

      assert {:ok, "zip-data"} = Denox.CLI.handle_response(response, 5)
    end

    test "returns error for non-200/non-redirect status" do
      response = {:ok, {{"HTTP/1.1", 404, "Not Found"}, [], "not found"}}

      assert {:error, msg} = Denox.CLI.handle_response(response, 5)
      assert msg =~ "Download failed (HTTP 404)"
    end

    test "returns error for redirect without Location header" do
      response = {:ok, {{"HTTP/1.1", 302, "Found"}, [], ""}}

      assert {:error, msg} = Denox.CLI.handle_response(response, 5)
      assert msg =~ "Redirect (HTTP 302) without Location header"
    end

    test "returns error for httpc error tuple" do
      response = {:error, :timeout}

      assert {:error, msg} = Denox.CLI.handle_response(response, 5)
      assert msg =~ "Download failed"
      assert msg =~ "timeout"
    end
  end

  describe "download/2 with zero redirects" do
    test "returns too many redirects error" do
      assert {:error, "Too many redirects"} = Denox.CLI.download("http://example.com", 0)
    end
  end

  describe "detect_os/0" do
    test "returns :linux or :macos on supported systems" do
      assert {:ok, os} = Denox.CLI.detect_os()
      assert os in [:linux, :macos]
    end
  end

  describe "detect_arch/0" do
    test "returns :x86_64 or :aarch64 on supported architectures" do
      assert {:ok, arch} = Denox.CLI.detect_arch()
      assert arch in [:x86_64, :aarch64]
    end
  end

  describe "detect_target/0" do
    test "returns a valid {os, arch} tuple" do
      assert {:ok, {os, arch}} = Denox.CLI.detect_target()
      assert os in [:linux, :macos]
      assert arch in [:x86_64, :aarch64]
    end
  end

  describe "download_url/2" do
    test "generates correct URL for macOS x86_64" do
      url = Denox.CLI.download_url("2.1.4", {:macos, :x86_64})

      assert url ==
               "https://github.com/denoland/deno/releases/download/v2.1.4/deno-x86_64-apple-darwin.zip"
    end

    test "generates correct URL for macOS aarch64" do
      url = Denox.CLI.download_url("2.1.4", {:macos, :aarch64})

      assert url ==
               "https://github.com/denoland/deno/releases/download/v2.1.4/deno-aarch64-apple-darwin.zip"
    end

    test "generates correct URL for Linux x86_64" do
      url = Denox.CLI.download_url("2.1.4", {:linux, :x86_64})

      assert url ==
               "https://github.com/denoland/deno/releases/download/v2.1.4/deno-x86_64-unknown-linux-gnu.zip"
    end

    test "generates correct URL for Linux aarch64" do
      url = Denox.CLI.download_url("2.1.4", {:linux, :aarch64})

      assert url ==
               "https://github.com/denoland/deno/releases/download/v2.1.4/deno-aarch64-unknown-linux-gnu.zip"
    end
  end

  describe "target_name/1" do
    test "formats macOS targets" do
      assert Denox.CLI.target_name({:macos, :x86_64}) == "macOS x86_64"
      assert Denox.CLI.target_name({:macos, :aarch64}) == "macOS aarch64"
    end

    test "formats Linux targets" do
      assert Denox.CLI.target_name({:linux, :x86_64}) == "Linux x86_64"
      assert Denox.CLI.target_name({:linux, :aarch64}) == "Linux aarch64"
    end
  end

  describe "cache_path/1" do
    test "returns expected path format" do
      assert Denox.CLI.cache_path("2.1.4") == "_build/denox_cli-2.1.4/deno"
    end
  end

  # Helper to create valid zip data in memory
  defp build_zip(files) do
    {:ok, {_name, zip_data}} = :zip.create(~c"test.zip", files, [:memory])
    zip_data
  end
end
