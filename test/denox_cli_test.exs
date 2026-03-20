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
  end
end
