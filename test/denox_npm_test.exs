defmodule DenoxNpmTest do
  use ExUnit.Case, async: false

  # Npm bundling tests require deno CLI.
  @moduletag :deno
  @moduletag :tmp_dir

  describe "bundle/3" do
    test "bundles an npm package", %{tmp_dir: dir} do
      output = Path.join(dir, "lodash.js")
      assert :ok = Denox.Npm.bundle("npm:lodash-es@4.17", output)
      assert File.exists?(output)
      assert File.stat!(output).size > 0
    end

    test "bundles with minify", %{tmp_dir: dir} do
      normal = Path.join(dir, "normal.js")
      minified = Path.join(dir, "minified.js")

      assert :ok = Denox.Npm.bundle("npm:lodash-es@4.17", normal)
      assert :ok = Denox.Npm.bundle("npm:lodash-es@4.17", minified, minify: true)

      assert File.stat!(minified).size < File.stat!(normal).size
    end

    test "returns error for invalid specifier", %{tmp_dir: dir} do
      output = Path.join(dir, "bad.js")
      assert {:error, msg} = Denox.Npm.bundle("npm:totally-nonexistent-pkg-xyz@0.0.0", output)
      assert is_binary(msg)
    end
  end

  describe "bundle!/3" do
    test "raises on failure", %{tmp_dir: dir} do
      output = Path.join(dir, "bad.js")

      assert_raise RuntimeError, fn ->
        Denox.Npm.bundle!("npm:totally-nonexistent-pkg-xyz@0.0.0", output)
      end
    end
  end

  describe "load/2" do
    test "loads a bundled file into a runtime", %{tmp_dir: dir} do
      # Create a simple JS file to load
      bundle = Path.join(dir, "test_bundle.js")
      File.write!(bundle, "globalThis.testLoaded = true;")

      {:ok, rt} = Denox.runtime()
      assert :ok = Denox.Npm.load(rt, bundle)
      assert {:ok, "true"} = Denox.eval(rt, "globalThis.testLoaded")
    end

    test "returns error for missing file" do
      {:ok, rt} = Denox.runtime()
      assert {:error, msg} = Denox.Npm.load(rt, "/nonexistent/bundle.js")
      assert msg =~ "Failed to read"
    end
  end

  describe "bundle_file/3" do
    test "bundles from an entrypoint file", %{tmp_dir: dir} do
      entrypoint = Path.join(dir, "entry.ts")
      output = Path.join(dir, "output.js")

      File.write!(entrypoint, """
      const greeting: string = "hello from bundle";
      console.log(greeting);
      """)

      assert :ok = Denox.Npm.bundle_file(entrypoint, output)
      assert File.exists?(output)
    end

    test "returns error for missing entrypoint", %{tmp_dir: dir} do
      output = Path.join(dir, "output.js")
      assert {:error, msg} = Denox.Npm.bundle_file("/nonexistent/entry.ts", output)
      assert msg =~ "not found"
    end
  end
end
