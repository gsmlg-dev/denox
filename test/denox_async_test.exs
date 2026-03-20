defmodule DenoxAsyncTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  setup do
    {:ok, rt} = Denox.runtime()
    %{rt: rt}
  end

  describe "eval_async/2 Promises" do
    test "resolves Promise.resolve", %{rt: rt} do
      assert {:ok, "42"} =
               Task.await(Denox.eval_async(rt, "export default await Promise.resolve(42)"))
    end

    test "rejects Promise.reject", %{rt: rt} do
      assert {:error, msg} =
               Task.await(Denox.eval_async(rt, ~s[export default await Promise.reject("fail")]))

      assert msg =~ "fail"
    end

    test "Promise chaining", %{rt: rt} do
      code = """
      export default await Promise.resolve(10)
        .then(x => x * 2)
        .then(x => x + 1)
      """

      assert {:ok, "21"} = Task.await(Denox.eval_async(rt, code))
    end

    test "async/await", %{rt: rt} do
      code = """
      async function fetchValue() {
        return 99;
      }
      export default await fetchValue();
      """

      assert {:ok, "99"} = Task.await(Denox.eval_async(rt, code))
    end

    test "returns undefined for void async", %{rt: rt} do
      assert {:ok, result} = Task.await(Denox.eval_async(rt, "await Promise.resolve()"))
      assert result == "undefined" or result == "null"
    end
  end

  describe "eval_ts_async/2" do
    test "TypeScript with async/await", %{rt: rt} do
      code = """
      async function compute(x: number): Promise<number> {
        return x * x;
      }
      export default await compute(7);
      """

      assert {:ok, "49"} = Task.await(Denox.eval_ts_async(rt, code))
    end

    test "TypeScript with typed Promise", %{rt: rt} do
      code = """
      interface Result { value: number }
      const p: Promise<Result> = Promise.resolve({ value: 42 });
      export default await p;
      """

      assert {:ok, json} = Task.await(Denox.eval_ts_async(rt, code))
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
      export default mod.VALUE;
      """

      assert {:ok, "123"} = Task.await(Denox.eval_async(rt, code))
    end
  end

  describe "eval_async/2 error handling" do
    test "returns error for ReferenceError during event-loop drain", %{rt: rt} do
      code = """
      await (async () => { throw new ReferenceError("Blob is not defined"); })();
      """

      assert {:error, msg} = Task.await(Denox.eval_async(rt, code))
      assert is_binary(msg)
    end

    test "returns error for TypeError in async code", %{rt: rt} do
      code = """
      const obj = undefined;
      export default await Promise.resolve(obj.property);
      """

      assert {:error, msg} = Task.await(Denox.eval_async(rt, code))
      assert is_binary(msg)
    end

    test "runtime remains usable after async error", %{rt: rt} do
      # Trigger an error
      code = """
      await (async () => { throw new Error("temporary failure"); })();
      """

      assert {:error, _} = Task.await(Denox.eval_async(rt, code))

      # Runtime should still work
      assert {:ok, "42"} = Task.await(Denox.eval_async(rt, "export default 42"))
    end
  end

  describe "eval_async/2 microtasks" do
    test "queueMicrotask resolves via event loop", %{rt: rt} do
      code = """
      export default await new Promise(resolve => {
        queueMicrotask(() => resolve(42));
      });
      """

      assert {:ok, "42"} = Task.await(Denox.eval_async(rt, code))
    end
  end

  describe "call_async/3" do
    test "calls async function", %{rt: rt} do
      Denox.exec(rt, """
      globalThis.asyncDouble = async function(n) {
        return n * 2;
      }
      """)

      assert {:ok, "10"} = Denox.call_async(rt, "asyncDouble", [5]) |> Task.await()
    end

    test "calls async function returning object", %{rt: rt} do
      Denox.exec(rt, """
      globalThis.fetchUser = async function(name) {
        return { name: name, active: true };
      }
      """)

      assert {:ok, %{"name" => "Alice", "active" => true}} =
               Denox.call_async_decode(rt, "fetchUser", ["Alice"]) |> Task.await()
    end
  end

  describe "eval_async_decode/2" do
    test "evaluates and decodes JSON result", %{rt: rt} do
      code = "export default {answer: 42, nested: {ok: true}}"
      task = Denox.eval_async_decode(rt, code)
      assert {:ok, %{"answer" => 42, "nested" => %{"ok" => true}}} = Task.await(task)
    end

    test "returns error for failing code", %{rt: rt} do
      code = "throw new Error('async decode fail')"
      task = Denox.eval_async_decode(rt, code)
      assert {:error, _} = Task.await(task)
    end
  end

  describe "eval_ts_async_decode/2" do
    test "evaluates TypeScript and decodes result", %{rt: rt} do
      code = """
      interface Data { x: number; y: string }
      const d: Data = { x: 10, y: "hello" };
      export default d;
      """

      task = Denox.eval_ts_async_decode(rt, code)
      assert {:ok, %{"x" => 10, "y" => "hello"}} = Task.await(task)
    end
  end
end
