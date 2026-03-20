defmodule DenoxNpmUnitTest do
  @moduledoc """
  Unit tests for Denox.Npm that do not require the Deno CLI.

  These cover `load/2` (NIF-only) and error paths that short-circuit
  before needing the CLI. Bundle tests are in denox_npm_test.exs (tagged :deno).
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
end
