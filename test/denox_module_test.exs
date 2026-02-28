defmodule DenoxModuleTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    {:ok, rt} = Denox.runtime(base_dir: tmp_dir)
    %{rt: rt, tmp_dir: tmp_dir}
  end

  describe "eval_module/2 basic" do
    test "loads and evaluates a JS module", %{rt: rt, tmp_dir: dir} do
      File.write!(Path.join(dir, "main.js"), """
      globalThis.moduleLoaded = true;
      """)

      assert {:ok, "undefined"} = Denox.eval_module(rt, Path.join(dir, "main.js"))
      assert {:ok, "true"} = Denox.eval(rt, "globalThis.moduleLoaded")
    end

    test "loads and evaluates a TS module", %{rt: rt, tmp_dir: dir} do
      File.write!(Path.join(dir, "main.ts"), """
      const x: number = 42;
      globalThis.tsResult = x;
      """)

      assert {:ok, "undefined"} = Denox.eval_module(rt, Path.join(dir, "main.ts"))
      assert {:ok, "42"} = Denox.eval(rt, "globalThis.tsResult")
    end
  end

  describe "eval_module/2 imports" do
    test "cross-file imports", %{rt: rt, tmp_dir: dir} do
      File.write!(Path.join(dir, "math.ts"), """
      export function add(a: number, b: number): number {
        return a + b;
      }

      export function multiply(a: number, b: number): number {
        return a * b;
      }
      """)

      File.write!(Path.join(dir, "main.ts"), """
      import { add, multiply } from "./math.ts";
      globalThis.sum = add(3, 4);
      globalThis.product = multiply(5, 6);
      """)

      assert {:ok, "undefined"} = Denox.eval_module(rt, Path.join(dir, "main.ts"))
      assert {:ok, "7"} = Denox.eval(rt, "globalThis.sum")
      assert {:ok, "30"} = Denox.eval(rt, "globalThis.product")
    end

    test "re-exports (barrel file)", %{rt: rt, tmp_dir: dir} do
      File.write!(Path.join(dir, "greet.ts"), """
      export function greet(name: string): string {
        return `Hello, ${name}!`;
      }
      """)

      File.write!(Path.join(dir, "index.ts"), """
      export { greet } from "./greet.ts";
      """)

      File.write!(Path.join(dir, "main.ts"), """
      import { greet } from "./index.ts";
      globalThis.greeting = greet("World");
      """)

      assert {:ok, "undefined"} = Denox.eval_module(rt, Path.join(dir, "main.ts"))
      assert {:ok, ~s("Hello, World!")} = Denox.eval(rt, "globalThis.greeting")
    end

    test "nested directory imports", %{rt: rt, tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "utils"))

      File.write!(Path.join(dir, "utils/helpers.ts"), """
      export const VERSION: string = "1.0.0";
      """)

      File.write!(Path.join(dir, "main.ts"), """
      import { VERSION } from "./utils/helpers.ts";
      globalThis.version = VERSION;
      """)

      assert {:ok, "undefined"} = Denox.eval_module(rt, Path.join(dir, "main.ts"))
      assert {:ok, ~s("1.0.0")} = Denox.eval(rt, "globalThis.version")
    end
  end

  describe "eval_module/2 error handling" do
    test "returns error for missing file", %{rt: rt, tmp_dir: dir} do
      assert {:error, msg} = Denox.eval_module(rt, Path.join(dir, "nonexistent.ts"))
      assert msg =~ "Failed to resolve path" or msg =~ "No such file"
    end

    test "returns error for missing import", %{rt: rt, tmp_dir: dir} do
      File.write!(Path.join(dir, "bad_import.ts"), """
      import { foo } from "./does_not_exist.ts";
      globalThis.result = foo;
      """)

      assert {:error, msg} = Denox.eval_module(rt, Path.join(dir, "bad_import.ts"))
      assert is_binary(msg)
    end

    test "returns error for TS syntax error in module", %{rt: rt, tmp_dir: dir} do
      File.write!(Path.join(dir, "bad_syntax.ts"), """
      export const x: number = ;
      """)

      assert {:error, msg} = Denox.eval_module(rt, Path.join(dir, "bad_syntax.ts"))
      assert is_binary(msg)
    end
  end

  describe "eval_module/2 JS interop" do
    test "mixed JS and TS modules", %{rt: rt, tmp_dir: dir} do
      File.write!(Path.join(dir, "config.js"), """
      export const PORT = 3000;
      export const HOST = "localhost";
      """)

      File.write!(Path.join(dir, "app.ts"), """
      import { PORT, HOST } from "./config.js";
      globalThis.addr = `${HOST}:${PORT}`;
      """)

      assert {:ok, "undefined"} = Denox.eval_module(rt, Path.join(dir, "app.ts"))
      assert {:ok, ~s("localhost:3000")} = Denox.eval(rt, "globalThis.addr")
    end
  end
end
