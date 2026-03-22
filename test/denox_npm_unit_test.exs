defmodule DenoxNpmUnitTest do
  @moduledoc """
  Unit tests for Denox.Npm.

  `load/2` tests use NIF only. Bundle tests use the system deno binary (no :deno tag
  since the binary is expected to be on PATH in the dev environment).
  Integration tests requiring npm network access are in denox_npm_test.exs (tagged :deno).
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  describe "load/2" do
    test "loads a JS file into a runtime and makes it executable", %{tmp_dir: dir} do
      bundle = Path.join(dir, "bundle.js")
      File.write!(bundle, "globalThis.npmLoaded = 42;")

      {:ok, rt} = Denox.runtime()
      assert :ok = Denox.Npm.load(rt, bundle)
      assert {:ok, "42"} = Denox.eval(rt, "globalThis.npmLoaded")
    end

    test "returns error when bundle file does not exist" do
      {:ok, rt} = Denox.runtime()
      assert {:error, msg} = Denox.Npm.load(rt, "/nonexistent/bundle.js")
      assert msg =~ "Failed to read"
    end
  end

  describe "bundle!/3" do
    test "raises when Deno CLI is not configured" do
      original = Application.get_env(:denox, :cli)

      on_exit(fn ->
        if original,
          do: Application.put_env(:denox, :cli, original),
          else: Application.delete_env(:denox, :cli)
      end)

      Application.delete_env(:denox, :cli)

      # bundle calls find_deno which fails → bundle returns error → bundle! raises
      unless System.find_executable("deno") do
        assert_raise RuntimeError, fn ->
          Denox.Npm.bundle!("npm:zod@3.22", "/tmp/zod_test.js")
        end
      end
    end
  end

  describe "bundle/3 — with local file specifier" do
    test "returns :ok when bundling a local TS file", %{tmp_dir: dir} do
      entry = Path.join(dir, "entry.ts")
      output = Path.join(dir, "out.js")
      File.write!(entry, "export const x = 1;")

      assert :ok = Denox.Npm.bundle("file://#{entry}", output)
      assert File.exists?(output)
    end

    test "returns error when specifier is invalid", %{tmp_dir: dir} do
      output = Path.join(dir, "out.js")
      result = Denox.Npm.bundle("file:///nonexistent_npm_entry_xyz.ts", output)
      assert {:error, msg} = result
      assert msg =~ "deno bundle failed"
    end

    test "returns :ok with minify option", %{tmp_dir: dir} do
      entry = Path.join(dir, "entry.ts")
      output = Path.join(dir, "out_min.js")
      File.write!(entry, "export const greeting = 'hello world';")

      assert :ok = Denox.Npm.bundle("file://#{entry}", output, minify: true)
      assert File.exists?(output)
    end

    test "returns :ok with platform option", %{tmp_dir: dir} do
      entry = Path.join(dir, "entry.ts")
      output = Path.join(dir, "out_browser.js")
      File.write!(entry, "export const y = 2;")

      assert :ok = Denox.Npm.bundle("file://#{entry}", output, platform: "browser")
      assert File.exists?(output)
    end

    test "returns :ok with config option", %{tmp_dir: dir} do
      entry = Path.join(dir, "entry.ts")
      output = Path.join(dir, "out_config.js")
      config = Path.join(dir, "deno.json")
      File.write!(entry, "export const z = 3;")
      File.write!(config, ~s({"imports":{}}))

      assert :ok = Denox.Npm.bundle("file://#{entry}", output, config: config)
      assert File.exists?(output)
    end
  end

  describe "bundle!/3 — with local file specifier" do
    test "returns :ok when bundling succeeds", %{tmp_dir: dir} do
      entry = Path.join(dir, "entry.ts")
      output = Path.join(dir, "out_bang.js")
      File.write!(entry, "export const v = 99;")

      assert :ok = Denox.Npm.bundle!("file://#{entry}", output)
    end

    test "raises when bundling fails", %{tmp_dir: dir} do
      output = Path.join(dir, "out.js")

      assert_raise RuntimeError, fn ->
        Denox.Npm.bundle!("file:///nonexistent_npm_bang_xyz.ts", output)
      end
    end
  end

  describe "bundle_file/3" do
    test "returns :ok when entrypoint exists and deno succeeds", %{tmp_dir: dir} do
      entry = Path.join(dir, "local_entry.ts")
      output = Path.join(dir, "local_out.js")
      File.write!(entry, "export const hello = 'world';")

      assert :ok = Denox.Npm.bundle_file(entry, output)
      assert File.exists?(output)
    end

    test "returns error when entrypoint does not exist", %{tmp_dir: dir} do
      output = Path.join(dir, "out.js")
      result = Denox.Npm.bundle_file(Path.join(dir, "nonexistent.ts"), output)
      assert {:error, msg} = result
      assert msg =~ "not found"
    end

    test "returns error when deno bundle fails on existing file", %{tmp_dir: dir} do
      # File exists but imports a local module that doesn't exist — causes deno to fail
      entry = Path.join(dir, "broken.ts")
      output = Path.join(dir, "broken_out.js")

      File.write!(
        entry,
        ~s[import { something } from "./nonexistent_dep.ts";\nexport { something };\n]
      )

      result = Denox.Npm.bundle_file(entry, output)
      assert {:error, msg} = result
      assert msg =~ "deno bundle failed"
    end
  end
end
