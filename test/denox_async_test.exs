defmodule DenoxAsyncTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  setup do
    {:ok, rt} = Denox.runtime()
    %{rt: rt}
  end

  describe "eval_async/2 Promises" do
    test "resolves Promise.resolve", %{rt: rt} do
      assert {:ok, "42"} = Denox.eval_async(rt, "return await Promise.resolve(42)")
    end

    test "rejects Promise.reject", %{rt: rt} do
      assert {:error, msg} = Denox.eval_async(rt, ~s[return await Promise.reject("fail")])
      assert msg =~ "fail"
    end

    test "Promise chaining", %{rt: rt} do
      code = """
      return await Promise.resolve(10)
        .then(x => x * 2)
        .then(x => x + 1)
      """

      assert {:ok, "21"} = Denox.eval_async(rt, code)
    end

    test "async/await", %{rt: rt} do
      code = """
      async function fetchValue() {
        return 99;
      }
      return await fetchValue();
      """

      assert {:ok, "99"} = Denox.eval_async(rt, code)
    end

    test "returns undefined for void async", %{rt: rt} do
      assert {:ok, result} = Denox.eval_async(rt, "await Promise.resolve()")
      assert result == "undefined" or result == "null"
    end
  end

  describe "eval_ts_async/2" do
    test "TypeScript with async/await", %{rt: rt} do
      code = """
      async function compute(x: number): Promise<number> {
        return x * x;
      }
      return await compute(7);
      """

      assert {:ok, "49"} = Denox.eval_ts_async(rt, code)
    end

    test "TypeScript with typed Promise", %{rt: rt} do
      code = """
      interface Result { value: number }
      const p: Promise<Result> = Promise.resolve({ value: 42 });
      return await p;
      """

      assert {:ok, json} = Denox.eval_ts_async(rt, code)
      assert {:ok, %{"value" => 42}} = Jason.decode(json)
    end
  end

  describe "eval_async/2 dynamic import" do
    test "dynamic import of local module", %{tmp_dir: dir} do
      {:ok, rt} = Denox.runtime(base_dir: dir)

      File.write!(Path.join(dir, "mod.ts"), """
      export const VALUE: number = 123;
      """)

      code = """
      const mod = await import("./mod.ts");
      return mod.VALUE;
      """

      assert {:ok, "123"} = Denox.eval_async(rt, code)
    end
  end

  describe "eval_async/2 microtasks" do
    test "queueMicrotask resolves via event loop", %{rt: rt} do
      code = """
      return await new Promise(resolve => {
        queueMicrotask(() => resolve(42));
      });
      """

      assert {:ok, "42"} = Denox.eval_async(rt, code)
    end
  end

  describe "call_async/3" do
    test "calls async function", %{rt: rt} do
      Denox.exec(rt, """
      globalThis.asyncDouble = async function(n) {
        return n * 2;
      }
      """)

      assert {:ok, "10"} = Denox.call_async(rt, "asyncDouble", [5])
    end

    test "calls async function returning object", %{rt: rt} do
      Denox.exec(rt, """
      globalThis.fetchUser = async function(name) {
        return { name: name, active: true };
      }
      """)

      assert {:ok, %{"name" => "Alice", "active" => true}} =
               Denox.call_async_decode(rt, "fetchUser", ["Alice"])
    end
  end
end
