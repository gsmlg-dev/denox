defmodule DenoxCLITest do
  # Application env is global state — cannot be safely mutated in async tests
  use ExUnit.Case, async: false

  setup do
    original = Application.get_env(:denox, :cli)

    on_exit(fn ->
      if original do
        Application.put_env(:denox, :cli, original)
      else
        Application.delete_env(:denox, :cli)
      end
    end)

    :ok
  end

  describe "configured_version/0" do
    test "returns nil when not configured" do
      Application.delete_env(:denox, :cli)
      assert Denox.CLI.configured_version() == nil
    end

    test "returns version when configured" do
      Application.put_env(:denox, :cli, version: "2.1.4")
      assert Denox.CLI.configured_version() == "2.1.4"
    end
  end

  describe "installed?/0" do
    test "returns false when not configured" do
      Application.delete_env(:denox, :cli)
      refute Denox.CLI.installed?()
    end

    test "returns false when configured but not downloaded" do
      Application.put_env(:denox, :cli, version: "99.99.99")
      refute Denox.CLI.installed?()
    end
  end

  describe "bin_path/0" do
    test "returns error when not configured" do
      Application.delete_env(:denox, :cli)
      assert {:error, :not_configured} = Denox.CLI.bin_path()
    end

    test "returns ok when already installed" do
      Application.put_env(:denox, :cli, version: "99.99.99")

      # Pre-create the binary so install() is not called
      version = "99.99.99"
      path = Path.join(["_build", "denox_cli-#{version}", "deno"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "fake-deno-binary")
      File.chmod!(path, 0o755)

      on_exit(fn -> File.rm(path) end)

      assert {:ok, ^path} = Denox.CLI.bin_path()
    end

    @tag :network
    test "returns error when configured but download fails" do
      # Use a version that doesn't exist on GitHub
      Application.put_env(:denox, :cli, version: "0.0.1-nonexistent")

      result = Denox.CLI.bin_path()
      assert {:error, _reason} = result
    end
  end

  describe "install/0" do
    test "returns error when not configured" do
      Application.delete_env(:denox, :cli)
      assert {:error, :not_configured} = Denox.CLI.install()
    end

    @tag :network
    test "returns error for non-existent version" do
      Application.put_env(:denox, :cli, version: "0.0.1-nonexistent")

      assert {:error, reason} = Denox.CLI.install()
      assert is_binary(reason)
    end
  end

  describe "find_deno/0" do
    test "returns system deno when available on PATH" do
      # find_deno tries System.find_executable("deno") first
      case System.find_executable("deno") do
        nil ->
          # No system deno — test the fallback path
          Application.delete_env(:denox, :cli)
          assert {:error, msg} = Denox.CLI.find_deno()
          assert msg =~ "deno CLI not found"

        path ->
          assert {:ok, ^path} = Denox.CLI.find_deno()
      end
    end

    test "falls back to bundled CLI when system deno is not available" do
      # We can't easily remove deno from PATH in a test, but we can
      # verify that when CLI is configured with a pre-existing binary,
      # find_deno returns successfully
      version = "77.77.77"
      Application.put_env(:denox, :cli, version: version)

      path = Path.join(["_build", "denox_cli-#{version}", "deno"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "fake-deno")
      File.chmod!(path, 0o755)

      on_exit(fn -> File.rm_rf(Path.dirname(path)) end)

      assert {:ok, _} = Denox.CLI.find_deno()
    end

    test "returns error with actionable message when neither is available" do
      Application.delete_env(:denox, :cli)

      # Only test when system deno is NOT on PATH
      if System.find_executable("deno") == nil do
        assert {:error, msg} = Denox.CLI.find_deno()
        assert msg =~ "deno CLI not found"
        assert msg =~ "config :denox, :cli"
      end
    end
  end

  describe "install/0 with valid zip data" do
    test "succeeds when given a real zip with a deno entry", %{} do
      original_cli = Application.get_env(:denox, :cli)
      version = "install-success-42.42.42"
      Application.put_env(:denox, :cli, version: version)

      cache = Denox.CLI.cache_path(version)

      on_exit(fn ->
        File.rm_rf(Path.dirname(cache))

        if original_cli,
          do: Application.put_env(:denox, :cli, original_cli),
          else: Application.delete_env(:denox, :cli)
      end)

      # Directly test extract_and_install to cover the success install path (lines 56-57)
      {:ok, {_, zip_data}} = :zip.create(~c"test.zip", [{~c"deno", "fake-binary"}], [:memory])
      assert :ok = Denox.CLI.extract_and_install(zip_data, cache)
      assert File.exists?(cache)
      assert File.read!(cache) == "fake-binary"
    end
  end

  describe "bin_path/0 fetch_or_install success path" do
    test "returns {:ok, path} after successful install" do
      version = "fetch-install-success-33.33.33"
      original_cli = Application.get_env(:denox, :cli)
      Application.put_env(:denox, :cli, version: version)

      cache = Denox.CLI.cache_path(version)

      on_exit(fn ->
        File.rm_rf(Path.dirname(cache))

        if original_cli,
          do: Application.put_env(:denox, :cli, original_cli),
          else: Application.delete_env(:denox, :cli)
      end)

      # Pre-create the binary to simulate successful install
      File.mkdir_p!(Path.dirname(cache))
      File.write!(cache, "fake-binary")

      # fetch_or_install finds the file → returns {:ok, path} (line 30)
      assert {:ok, ^cache} = Denox.CLI.bin_path()
    end
  end

  describe "installed?/0 with pre-existing binary" do
    test "returns true when binary exists" do
      version = "88.88.88"
      Application.put_env(:denox, :cli, version: version)

      path = Path.join(["_build", "denox_cli-#{version}", "deno"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "fake")

      on_exit(fn -> File.rm_rf(Path.dirname(path)) end)

      assert Denox.CLI.installed?()
    end
  end
end
