defmodule DenoxCLIUnitTest do
  @moduledoc """
  Unit tests for Denox.CLI covering error paths and fallback logic.
  async: false because some tests modify PATH and Application env.
  """
  use ExUnit.Case, async: false

  describe "bin_path/0 — fetch_or_install path" do
    @tag timeout: 120_000
    test "returns error when version configured but binary missing (triggers install)" do
      original_cli = Application.get_env(:denox, :cli)
      version = "999.999.999-no-binary-test"
      Application.put_env(:denox, :cli, version: version)

      on_exit(fn ->
        if original_cli,
          do: Application.put_env(:denox, :cli, original_cli),
          else: Application.delete_env(:denox, :cli)
      end)

      # Binary doesn't exist → fetch_or_install → install() → HTTP 404 → {:error, ...}
      assert {:error, _} = Denox.CLI.bin_path()
    end

    test "returns {:ok, path} when version configured and binary exists" do
      original_cli = Application.get_env(:denox, :cli)
      version = "test-bin-path-77.77.77"
      cli_dir = "_build/denox_cli-#{version}"
      cli_path = Path.join(cli_dir, "deno")

      File.mkdir_p!(cli_dir)
      File.write!(cli_path, "fake-binary")

      Application.put_env(:denox, :cli, version: version)

      on_exit(fn ->
        if original_cli,
          do: Application.put_env(:denox, :cli, original_cli),
          else: Application.delete_env(:denox, :cli)

        File.rm_rf(cli_dir)
      end)

      assert {:ok, ^cli_path} = Denox.CLI.bin_path()
    end
  end

  describe "find_deno/0 — bundled CLI fallback" do
    setup do
      original_path = System.get_env("PATH")
      original_cli = Application.get_env(:denox, :cli)

      on_exit(fn ->
        System.put_env("PATH", original_path)

        if original_cli,
          do: Application.put_env(:denox, :cli, original_cli),
          else: Application.delete_env(:denox, :cli)
      end)

      # Use a path that definitely won't contain deno
      {:ok, original_path: original_path}
    end

    test "returns error when deno not on PATH and no CLI configured" do
      Application.delete_env(:denox, :cli)
      System.put_env("PATH", "/tmp")

      assert {:error, msg} = Denox.CLI.find_deno()
      assert msg =~ "deno CLI not found"
    end

    test "returns {:ok, path} when deno not on PATH but bundled CLI binary exists" do
      version = "test-find-deno-66.66.66"
      cli_dir = "_build/denox_cli-#{version}"
      cli_path = Path.join(cli_dir, "deno")

      File.mkdir_p!(cli_dir)
      File.write!(cli_path, "#!/bin/sh\necho fake")
      File.chmod!(cli_path, 0o755)

      Application.put_env(:denox, :cli, version: version)
      System.put_env("PATH", "/tmp")

      on_exit(fn -> File.rm_rf(cli_dir) end)

      assert {:ok, ^cli_path} = Denox.CLI.find_deno()
    end

    test "returns system deno when deno IS on PATH (system takes priority over bundled CLI)" do
      # Create a fake deno binary in a temp dir and prepend to PATH
      tmp_dir =
        Path.join(System.tmp_dir!(), "denox-findeno-test-#{System.unique_integer([:positive])}")

      fake_deno = Path.join(tmp_dir, "deno")

      File.mkdir_p!(tmp_dir)
      File.write!(fake_deno, "#!/bin/sh\necho fake-system-deno")
      File.chmod!(fake_deno, 0o755)

      original_path = System.get_env("PATH", "")
      System.put_env("PATH", "#{tmp_dir}:#{original_path}")

      on_exit(fn ->
        System.put_env("PATH", original_path)
        File.rm_rf!(tmp_dir)
      end)

      # System deno is found — should return it regardless of bundled CLI config
      assert {:ok, ^fake_deno} = Denox.CLI.find_deno()
    end
  end
end
