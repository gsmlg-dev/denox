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

    test "Deno.core.ops.op_elixir_call is not exposed (callback uses direct V8 binding)" do
      {:ok, rt} = Denox.runtime(sandbox: true)
      # The Denox callback is installed as a direct V8 function binding, not a
      # deno_core op, so Deno.core.ops.op_elixir_call does not exist.
      assert {:error, _} = Denox.eval(rt, "Deno.core.ops.op_elixir_call('test', '[]')")
    end

    test "non-sandbox with callbacks has callback op available" do
      handler = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, rt} = Denox.runtime(callback_pid: handler)
      # The Denox.callback global should be registered
      assert {:ok, "\"function\""} = Denox.eval(rt, "typeof Denox.callback")
    end
  end

  describe "permissions option" do
    test "permissions: :all creates a permissive runtime" do
      {:ok, rt} = Denox.runtime(permissions: :all)
      assert {:ok, "3"} = Denox.eval(rt, "1 + 2")
    end

    test "permissions: :none creates a restricted runtime" do
      {:ok, rt} = Denox.runtime(permissions: :none)
      assert {:ok, "3"} = Denox.eval(rt, "1 + 2")
    end

    test "granular permissions with keyword list" do
      {:ok, rt} = Denox.runtime(permissions: [allow_env: true])
      assert {:ok, "3"} = Denox.eval(rt, "1 + 2")
    end

    test "granular permissions with list values" do
      {:ok, rt} = Denox.runtime(permissions: [allow_read: ["/tmp"]])
      assert {:ok, "3"} = Denox.eval(rt, "1 + 2")
    end

    test "granular permissions ignores false entries" do
      {:ok, rt} = Denox.runtime(permissions: [allow_env: true, allow_net: false])
      assert {:ok, "3"} = Denox.eval(rt, "1 + 2")
    end

    test "default (no permissions option) creates a permissive runtime" do
      {:ok, rt} = Denox.runtime()
      assert {:ok, "3"} = Denox.eval(rt, "1 + 2")
    end
  end
end
