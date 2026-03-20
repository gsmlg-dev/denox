defmodule DenoxCLITest do
  use ExUnit.Case, async: true

  describe "configured_version/0" do
    test "returns nil when not configured" do
      # Default state — no :cli config set
      original = Application.get_env(:denox, :cli)
      Application.delete_env(:denox, :cli)

      assert Denox.CLI.configured_version() == nil

      if original, do: Application.put_env(:denox, :cli, original)
    end

    test "returns version when configured" do
      original = Application.get_env(:denox, :cli)
      Application.put_env(:denox, :cli, version: "2.1.4")

      assert Denox.CLI.configured_version() == "2.1.4"

      if original do
        Application.put_env(:denox, :cli, original)
      else
        Application.delete_env(:denox, :cli)
      end
    end
  end

  describe "installed?/0" do
    test "returns false when not configured" do
      original = Application.get_env(:denox, :cli)
      Application.delete_env(:denox, :cli)

      refute Denox.CLI.installed?()

      if original, do: Application.put_env(:denox, :cli, original)
    end

    test "returns false when configured but not downloaded" do
      original = Application.get_env(:denox, :cli)
      Application.put_env(:denox, :cli, version: "99.99.99")

      refute Denox.CLI.installed?()

      if original do
        Application.put_env(:denox, :cli, original)
      else
        Application.delete_env(:denox, :cli)
      end
    end
  end

  describe "bin_path/0" do
    test "returns error when not configured" do
      original = Application.get_env(:denox, :cli)
      Application.delete_env(:denox, :cli)

      assert {:error, :not_configured} = Denox.CLI.bin_path()

      if original, do: Application.put_env(:denox, :cli, original)
    end

    test "returns ok when already installed" do
      original = Application.get_env(:denox, :cli)
      Application.put_env(:denox, :cli, version: "99.99.99")

      # Pre-create the binary so install() is not called
      version = "99.99.99"
      path = Path.join(["_build", "denox_cli-#{version}", "deno"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "fake-deno-binary")
      File.chmod!(path, 0o755)

      assert {:ok, ^path} = Denox.CLI.bin_path()

      File.rm!(path)

      if original do
        Application.put_env(:denox, :cli, original)
      else
        Application.delete_env(:denox, :cli)
      end
    end

    @tag :network
    test "returns error when configured but download fails" do
      original = Application.get_env(:denox, :cli)
      # Use a version that doesn't exist on GitHub
      Application.put_env(:denox, :cli, version: "0.0.1-nonexistent")

      result = Denox.CLI.bin_path()
      assert {:error, _reason} = result

      if original do
        Application.put_env(:denox, :cli, original)
      else
        Application.delete_env(:denox, :cli)
      end
    end
  end

  describe "install/0" do
    test "returns error when not configured" do
      original = Application.get_env(:denox, :cli)
      Application.delete_env(:denox, :cli)

      assert {:error, :not_configured} = Denox.CLI.install()

      if original, do: Application.put_env(:denox, :cli, original)
    end
  end
end
