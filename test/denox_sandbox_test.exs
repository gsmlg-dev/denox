defmodule DenoxSandboxTest do
  use ExUnit.Case, async: true

  describe "sandbox mode" do
    test "creates a sandbox runtime" do
      {:ok, rt} = Denox.runtime(sandbox: true)
      assert {:ok, "3"} = Denox.eval(rt, "1 + 2")
    end

    test "sandbox runtime evaluates basic JavaScript" do
      {:ok, rt} = Denox.runtime(sandbox: true)
      assert {:ok, ~s("hello")} = Denox.eval(rt, "'hello'")
    end

    test "sandbox runtime evaluates TypeScript" do
      {:ok, rt} = Denox.runtime(sandbox: true)
      assert {:ok, "42"} = Denox.eval_ts(rt, "const x: number = 42; x")
    end

    test "sandbox runtime handles errors" do
      {:ok, rt} = Denox.runtime(sandbox: true)
      assert {:error, _} = Denox.eval(rt, "throw new Error('boom')")
    end

    test "sandbox runtime has globalThis" do
      {:ok, rt} = Denox.runtime(sandbox: true)
      assert {:ok, _} = Denox.eval(rt, "typeof globalThis")
    end

    test "sandbox runtime state persists" do
      {:ok, rt} = Denox.runtime(sandbox: true)
      :ok = Denox.exec(rt, "globalThis.x = 42")
      assert {:ok, "42"} = Denox.eval(rt, "globalThis.x")
    end

    test "non-sandbox mode works normally" do
      {:ok, rt} = Denox.runtime(sandbox: false)
      assert {:ok, "3"} = Denox.eval(rt, "1 + 2")
    end

    test "default is non-sandbox" do
      {:ok, rt} = Denox.runtime()
      assert {:ok, "3"} = Denox.eval(rt, "1 + 2")
    end

    test "sandbox strips extensions (callback op unavailable)" do
      {:ok, rt} = Denox.runtime(sandbox: true)
      # In sandbox mode, extensions are stripped so callback op is not registered
      assert {:error, _} = Denox.eval(rt, "Deno.core.ops.op_elixir_call('test', '[]')")
    end

    test "non-sandbox with callbacks has callback op available" do
      handler = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, rt} = Denox.runtime(callback_pid: handler)
      # The callback op should be registered
      assert {:ok, "\"function\""} = Denox.eval(rt, "typeof Deno.core.ops.op_elixir_call")
    end
  end
end
