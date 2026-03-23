defmodule Denox.E2E.ScriptCallTest do
  use ExUnit.Case, async: true

  @scripts_dir Path.expand("scripts", __DIR__)

  setup do
    {:ok, rt} = Denox.runtime()
    %{rt: rt}
  end

  describe "define functions in scripts then call them" do
    test "load script and call defined function", %{rt: rt} do
      # Define functions via eval_file
      Denox.eval_file(rt, Path.join(@scripts_dir, "callable_funcs.js"))

      assert {:ok, 8} = Denox.call_decode(rt, "add", [3, 5])
      assert {:ok, 15} = Denox.call_decode(rt, "multiply", [3, 5])
    end

    test "load TypeScript script and call defined function", %{rt: rt} do
      Denox.eval_file(rt, Path.join(@scripts_dir, "callable_funcs.ts"))

      assert {:ok, "HELLO, WORLD"} = Denox.call_decode(rt, "shout", ["hello, world"])
      assert {:ok, true} = Denox.call_decode(rt, "isEven", [42])
      assert {:ok, false} = Denox.call_decode(rt, "isEven", [7])
    end

    test "call function returning complex object", %{rt: rt} do
      Denox.exec(rt, """
      globalThis.buildUser = (name, age) => ({
        name,
        age,
        adult: age >= 18,
        greeting: `Hello, ${name}!`
      });
      """)

      assert {:ok, result} = Denox.call_decode(rt, "buildUser", ["Alice", 30])
      assert result["name"] == "Alice"
      assert result["age"] == 30
      assert result["adult"] == true
      assert result["greeting"] == "Hello, Alice!"
    end
  end

  describe "async function calls from scripts" do
    test "call async function defined in script", %{rt: rt} do
      Denox.exec(rt, """
      globalThis.asyncSum = async (numbers) => {
        await new Promise(r => setTimeout(r, 5));
        return numbers.reduce((a, b) => a + b, 0);
      };
      """)

      task = Denox.call_async_decode(rt, "asyncSum", [[1, 2, 3, 4, 5]])
      assert {:ok, 15} = Task.await(task, 10_000)
    end
  end
end
