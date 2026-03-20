defmodule DenoxMixTasksTest do
  @moduledoc """
  Tests for Mix tasks that can run without Deno CLI.
  Tests the argument validation and error path behaviors.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  describe "mix denox.add" do
    test "raises when called with wrong number of arguments" do
      Mix.Task.reenable("denox.add")

      assert_raise Mix.Error, ~r/Usage: mix denox.add/, fn ->
        Mix.Task.run("denox.add", [])
      end
    end

    test "raises when called with only one argument" do
      Mix.Task.reenable("denox.add")

      assert_raise Mix.Error, ~r/Usage: mix denox.add/, fn ->
        Mix.Task.run("denox.add", ["zod"])
      end
    end

    test "raises when Deps.add fails (invalid config path)" do
      Mix.Task.reenable("denox.add")

      # A config path in a non-existent directory causes Deps.add to return {:error, ...}
      # which causes Mix.raise to be called
      assert_raise Mix.Error, fn ->
        Mix.Task.run("denox.add", [
          "zod",
          "npm:zod@^3.22",
          "--config",
          "/nonexistent_dir_abc/deno.json"
        ])
      end
    end

    test "prints success when add succeeds with empty deno.json", %{tmp_dir: dir} do
      Mix.Task.reenable("denox.add")
      config = Path.join(dir, "deno.json")
      File.write!(config, ~s({"imports":{}}))

      # file: specifier with a local file — deno install runs fast with no real packages
      local_js = Path.join(dir, "local.js")
      File.write!(local_js, "export const x = 1;")

      # Should print "Added localpkg successfully." without raising
      Mix.Task.run("denox.add", ["localpkg", "file:./local.js", "--config", config])
    end
  end

  describe "mix denox.remove" do
    test "raises when called with no arguments" do
      Mix.Task.reenable("denox.remove")

      assert_raise Mix.Error, ~r/Usage: mix denox.remove/, fn ->
        Mix.Task.run("denox.remove", [])
      end
    end

    test "raises when Deps.remove fails (config not found)" do
      Mix.Task.reenable("denox.remove")

      # Config doesn't exist → check_config returns error → Mix.raise
      assert_raise Mix.Error, fn ->
        Mix.Task.run("denox.remove", ["zod", "--config", "/nonexistent_dir/deno.json"])
      end
    end

    test "prints success when remove succeeds with empty deno.json", %{tmp_dir: dir} do
      Mix.Task.reenable("denox.remove")
      config = Path.join(dir, "deno.json")
      File.write!(config, ~s({"imports":{"oldpkg":"npm:oldpkg@1.0"}}))

      # Removing a pkg that may or may not exist — deno install with empty imports exits 0
      Mix.Task.run("denox.remove", ["oldpkg", "--config", config])
    end
  end

  describe "mix denox.install" do
    test "raises when config file does not exist" do
      Mix.Task.reenable("denox.install")

      # check_config fails when config doesn't exist → Deps.install returns error → Mix.raise
      assert_raise Mix.Error, fn ->
        Mix.Task.run("denox.install", ["--config", "/nonexistent_install_dir/deno.json"])
      end
    end

    test "prints success when install succeeds with empty deno.json", %{tmp_dir: dir} do
      Mix.Task.reenable("denox.install")
      config = Path.join(dir, "deno.json")
      File.write!(config, ~s({"imports":{}}))

      # deno install with empty imports exits 0 — prints "Dependencies installed successfully."
      Mix.Task.run("denox.install", ["--config", config])
    end
  end

  describe "mix denox.bundle" do
    test "raises when called with wrong number of arguments" do
      Mix.Task.reenable("denox.bundle")

      assert_raise Mix.Error, ~r/Usage: mix denox.bundle/, fn ->
        Mix.Task.run("denox.bundle", [])
      end
    end

    test "raises when called with only one argument" do
      Mix.Task.reenable("denox.bundle")

      assert_raise Mix.Error, ~r/Usage: mix denox.bundle/, fn ->
        Mix.Task.run("denox.bundle", ["npm:zod@3.22"])
      end
    end

    test "prints success when bundle succeeds with a local TS file", %{tmp_dir: dir} do
      Mix.Task.reenable("denox.bundle")
      entrypoint = Path.join(dir, "entry.ts")
      output = Path.join(dir, "out.js")
      File.write!(entrypoint, "export const x = 42;")

      # deno bundle with a local file specifier should succeed
      Mix.Task.run("denox.bundle", ["file://#{entrypoint}", output])
      assert File.exists?(output)
    end

    test "raises when bundle fails (bad specifier)", %{tmp_dir: dir} do
      Mix.Task.reenable("denox.bundle")
      output = Path.join(dir, "out.js")

      assert_raise Mix.Error, fn ->
        Mix.Task.run("denox.bundle", ["file:///nonexistent_entry.ts", output])
      end
    end
  end

  describe "mix denox.run" do
    test "raises when called with no arguments" do
      Mix.Task.reenable("denox.run")

      assert_raise Mix.Error, ~r/Usage: mix denox.run/, fn ->
        Mix.Task.run("denox.run", [])
      end
    end

    test "raises when only -- separator with no specifier before it" do
      Mix.Task.reenable("denox.run")

      # ["--", "extra"] → script_args=["extra"], positional=[] → specifier=nil → raises
      assert_raise Mix.Error, ~r/Usage: mix denox.run/, fn ->
        Mix.Task.run("denox.run", ["--", "extra"])
      end
    end

    test "runs a local script successfully", %{tmp_dir: dir} do
      Mix.Task.reenable("denox.run")
      script = Path.join(dir, "noop.ts")
      File.write!(script, "// empty\n")

      Mix.Task.run("denox.run", ["file://#{script}"])
    end

    test "covers --allow-all flag alias", %{tmp_dir: dir} do
      Mix.Task.reenable("denox.run")
      script = Path.join(dir, "noop2.ts")
      File.write!(script, "// noop\n")

      Mix.Task.run("denox.run", ["--allow-all", "file://#{script}"])
    end

    test "covers -- separator with args passed to script", %{tmp_dir: dir} do
      Mix.Task.reenable("denox.run")
      script = Path.join(dir, "noop3.ts")
      File.write!(script, "// noop\n")

      Mix.Task.run("denox.run", ["file://#{script}", "--", "arg1"])
    end

    test "raises when deno script exits with non-zero status", %{tmp_dir: dir} do
      Mix.Task.reenable("denox.run")
      script = Path.join(dir, "fail.ts")
      File.write!(script, "Deno.exit(1);")

      assert_raise Mix.Error, ~r/exited with status 1/, fn ->
        Mix.Task.run("denox.run", ["file://#{script}"])
      end
    end

    test "covers --allow-net flag and passes it through", %{tmp_dir: dir} do
      Mix.Task.reenable("denox.run")
      script = Path.join(dir, "noop4.ts")
      File.write!(script, "// noop\n")

      Mix.Task.run("denox.run", ["--allow-net", "file://#{script}"])
    end
  end

  describe "mix denox.cli.install" do
    test "raises when no version is configured" do
      Mix.Task.reenable("denox.cli.install")
      original = Application.get_env(:denox, :cli)

      on_exit(fn ->
        if original,
          do: Application.put_env(:denox, :cli, original),
          else: Application.delete_env(:denox, :cli)
      end)

      Application.delete_env(:denox, :cli)

      assert_raise Mix.Error, ~r/No Deno CLI version configured/, fn ->
        Mix.Task.run("denox.cli.install", [])
      end
    end

    test "prints 'already installed' when binary exists and not forced" do
      Mix.Task.reenable("denox.cli.install")
      version = "55.55.55"
      original = Application.get_env(:denox, :cli)

      Application.put_env(:denox, :cli, version: version)

      path = Path.join(["_build", "denox_cli-#{version}", "deno"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "fake-binary")

      on_exit(fn ->
        File.rm_rf(Path.dirname(path))

        if original,
          do: Application.put_env(:denox, :cli, original),
          else: Application.delete_env(:denox, :cli)
      end)

      # No error raised — task prints "already installed"
      Mix.Task.run("denox.cli.install", [])
    end
  end
end
