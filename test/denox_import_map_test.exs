defmodule Denox.ImportMapTest do
  use ExUnit.Case, async: true

  describe "import map - exact match" do
    test "resolves bare specifier to local file" do
      tmp_dir = System.tmp_dir!()
      dir = Path.join(tmp_dir, "denox_imap_exact_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      on_exit(fn -> File.rm_rf!(dir) end)

      # Create a module that exports a value
      File.write!(Path.join(dir, "my_math.ts"), """
      export const PI = 3.14159;
      """)

      math_url = "file://" <> Path.join(dir, "my_math.ts")

      {:ok, rt} =
        Denox.runtime(
          base_dir: dir,
          import_map: %{"math" => math_url}
        )

      {:ok, result} =
        Denox.eval_async(rt, """
        const mod = await import("math");
        return mod.PI;
        """)

      assert result == "3.14159"
    end

    test "resolves multiple bare specifiers to different files" do
      tmp_dir = System.tmp_dir!()
      dir = Path.join(tmp_dir, "denox_imap_multi_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(dir, "foo.js"), "export const FOO = 'foo';")
      File.write!(Path.join(dir, "bar.js"), "export const BAR = 'bar';")

      {:ok, rt} =
        Denox.runtime(
          base_dir: dir,
          import_map: %{
            "foo" => "file://" <> Path.join(dir, "foo.js"),
            "bar" => "file://" <> Path.join(dir, "bar.js")
          }
        )

      {:ok, result} =
        Denox.eval_async(rt, """
        const { FOO } = await import("foo");
        const { BAR } = await import("bar");
        return FOO + BAR;
        """)

      assert result == "\"foobar\""
    end
  end

  describe "import map - prefix match" do
    test "resolves prefix-mapped specifiers" do
      tmp_dir = System.tmp_dir!()
      dir = Path.join(tmp_dir, "denox_imap_prefix_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(dir, "add.ts"), """
      export function add(a: number, b: number): number { return a + b; }
      """)

      File.write!(Path.join(dir, "mul.ts"), """
      export function mul(a: number, b: number): number { return a * b; }
      """)

      base_url = "file://" <> dir <> "/"

      {:ok, rt} =
        Denox.runtime(
          base_dir: dir,
          import_map: %{"mylib/" => base_url}
        )

      {:ok, result} =
        Denox.eval_async(rt, """
        const { add } = await import("mylib/add.ts");
        const { mul } = await import("mylib/mul.ts");
        return add(2, 3) * mul(4, 5);
        """)

      # add(2,3)=5, mul(4,5)=20, 5*20=100
      assert result == "100"
    end
  end

  describe "import map - module loading" do
    test "import map works with eval_module" do
      tmp_dir = System.tmp_dir!()
      dir = Path.join(tmp_dir, "denox_imap_mod_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(dir, "helper.ts"), """
      export const greeting = "hello from import map";
      """)

      helper_url = "file://" <> Path.join(dir, "helper.ts")

      File.write!(Path.join(dir, "main.ts"), """
      import { greeting } from "helper";
      (globalThis as any).__result = greeting;
      """)

      {:ok, rt} =
        Denox.runtime(
          base_dir: dir,
          import_map: %{"helper" => helper_url}
        )

      {:ok, _} = Denox.eval_module(rt, Path.join(dir, "main.ts"))
      {:ok, result} = Denox.eval(rt, "globalThis.__result")
      assert result == "\"hello from import map\""
    end
  end

  describe "import map - empty/no import map" do
    test "runtime works without import map" do
      {:ok, rt} = Denox.runtime()
      {:ok, result} = Denox.eval(rt, "1 + 2")
      assert result == "3"
    end

    test "runtime works with empty import map" do
      {:ok, rt} = Denox.runtime(import_map: %{})
      {:ok, result} = Denox.eval(rt, "1 + 2")
      assert result == "3"
    end
  end

  describe "import map - pool" do
    test "pool passes import map to runtimes" do
      tmp_dir = System.tmp_dir!()
      dir = Path.join(tmp_dir, "denox_imap_pool_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(dir, "value.ts"), """
      export const VALUE = 99;
      """)

      value_url = "file://" <> Path.join(dir, "value.ts")

      pool = :"imap_pool_#{:erlang.unique_integer([:positive])}"

      {:ok, _} =
        Denox.Pool.start_link(
          name: pool,
          size: 2,
          base_dir: dir,
          import_map: %{"value" => value_url}
        )

      {:ok, result} =
        Denox.Pool.eval_async(pool, """
        const mod = await import("value");
        return mod.VALUE;
        """)

      assert result == "99"
    end
  end
end
