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
  end
end
