defmodule DenoxCdnTest do
  use ExUnit.Case, async: false

  # All CDN tests require network access and are excluded by default.
  # Run with: mix test --include cdn
  @moduletag :cdn
  @moduletag :tmp_dir

  describe "CDN imports via eval_async" do
    test "imports from esm.sh", %{tmp_dir: dir} do
      {:ok, rt} = Denox.runtime(cache_dir: Path.join(dir, "cache"))

      code = """
      const { z } = await import("https://esm.sh/zod@3.22.4");
      const schema = z.object({ name: z.string() });
      return schema.parse({ name: "hello" });
      """

      assert {:ok, json} = Denox.eval_async(rt, code)
      assert {:ok, %{"name" => "hello"}} = Jason.decode(json)
    end

    test "caching: second import uses cache", %{tmp_dir: dir} do
      cache_path = Path.join(dir, "cache")
      {:ok, rt} = Denox.runtime(cache_dir: cache_path)

      # First import — fetches from network
      code = """
      const mod = await import("https://esm.sh/lodash-es@4.17.21/add");
      return mod.default(2, 3);
      """

      assert {:ok, "5"} = Denox.eval_async(rt, code)

      # Verify cache dir was populated
      assert File.ls!(cache_path) != []

      # Second import on same runtime — should use in-memory cache
      code2 = """
      const mod = await import("https://esm.sh/lodash-es@4.17.21/add");
      return mod.default(10, 20);
      """

      assert {:ok, "30"} = Denox.eval_async(rt, code2)
    end

    test "disk cache persists across runtimes", %{tmp_dir: dir} do
      cache_path = Path.join(dir, "cache")

      # First runtime — fetches and caches
      {:ok, rt1} = Denox.runtime(cache_dir: cache_path)

      code = """
      const mod = await import("https://esm.sh/lodash-es@4.17.21/add");
      return mod.default(1, 2);
      """

      assert {:ok, "3"} = Denox.eval_async(rt1, code)

      # Second runtime — should read from disk cache (no network)
      {:ok, rt2} = Denox.runtime(cache_dir: cache_path)

      assert {:ok, "3"} = Denox.eval_async(rt2, code)
    end

    test "error: invalid URL returns error" do
      {:ok, rt} = Denox.runtime()

      code = """
      return await import("https://this-domain-definitely-does-not-exist-12345.invalid/mod.js");
      """

      assert {:error, msg} = Denox.eval_async(rt, code)
      assert is_binary(msg)
    end
  end

  describe "CDN imports via eval_module" do
    test "module with CDN import", %{tmp_dir: dir} do
      {:ok, rt} = Denox.runtime(base_dir: dir, cache_dir: Path.join(dir, "cache"))

      File.write!(Path.join(dir, "cdn_test.js"), """
      import add from "https://esm.sh/lodash-es@4.17.21/add";
      globalThis.cdnResult = add(100, 200);
      """)

      assert {:ok, "undefined"} = Denox.eval_module(rt, Path.join(dir, "cdn_test.js"))
      assert {:ok, "300"} = Denox.eval(rt, "globalThis.cdnResult")
    end
  end
end
