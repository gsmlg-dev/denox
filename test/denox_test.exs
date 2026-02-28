defmodule DenoxTest do
  use ExUnit.Case, async: true

  describe "runtime/1" do
    test "creates a runtime" do
      assert {:ok, _rt} = Denox.runtime()
    end
  end

  describe "eval/2" do
    setup do
      {:ok, rt} = Denox.runtime()
      %{rt: rt}
    end

    test "evaluates arithmetic", %{rt: rt} do
      assert {:ok, "3"} = Denox.eval(rt, "1 + 2")
    end

    test "evaluates string expressions", %{rt: rt} do
      assert {:ok, ~s("hello world")} = Denox.eval(rt, "'hello' + ' ' + 'world'")
    end

    test "evaluates objects as JSON", %{rt: rt} do
      assert {:ok, json} = Denox.eval(rt, "({a: 1, b: 'two'})")
      assert {:ok, %{"a" => 1, "b" => "two"}} = Jason.decode(json)
    end

    test "evaluates arrays", %{rt: rt} do
      assert {:ok, "[1,2,3]"} = Denox.eval(rt, "[1, 2, 3]")
    end

    test "evaluates nested structures", %{rt: rt} do
      assert {:ok, json} = Denox.eval(rt, "({users: [{name: 'Alice', age: 30}]})")
      assert {:ok, %{"users" => [%{"name" => "Alice", "age" => 30}]}} = Jason.decode(json)
    end

    test "evaluates booleans", %{rt: rt} do
      assert {:ok, "true"} = Denox.eval(rt, "true")
      assert {:ok, "false"} = Denox.eval(rt, "false")
    end

    test "evaluates null", %{rt: rt} do
      assert {:ok, "null"} = Denox.eval(rt, "null")
    end

    test "returns error for syntax errors", %{rt: rt} do
      assert {:error, msg} = Denox.eval(rt, "function(")
      assert is_binary(msg)
    end

    test "returns error for runtime errors", %{rt: rt} do
      assert {:error, msg} = Denox.eval(rt, "undefinedVariable.property")
      assert is_binary(msg)
    end

    test "returns error for throw", %{rt: rt} do
      assert {:error, _msg} = Denox.eval(rt, "throw new Error('boom')")
    end
  end

  describe "runtime isolation" do
    test "two runtimes do not share state" do
      {:ok, rt1} = Denox.runtime()
      {:ok, rt2} = Denox.runtime()

      Denox.exec(rt1, "globalThis.shared = 42")
      assert {:ok, "42"} = Denox.eval(rt1, "globalThis.shared")

      # rt2 should not see rt1's state
      assert {:error, _msg} = Denox.eval(rt2, "globalThis.shared.toString()")
    end
  end

  describe "state persistence" do
    test "globalThis mutations persist within a runtime" do
      {:ok, rt} = Denox.runtime()

      Denox.exec(rt, "globalThis.counter = 0")
      Denox.exec(rt, "globalThis.counter += 1")
      Denox.exec(rt, "globalThis.counter += 1")

      assert {:ok, "2"} = Denox.eval(rt, "globalThis.counter")
    end

    test "var declarations persist", %{} do
      {:ok, rt} = Denox.runtime()

      Denox.exec(rt, "var myVar = 'hello'")
      assert {:ok, ~s("hello")} = Denox.eval(rt, "myVar")
    end
  end

  describe "exec/2" do
    test "returns :ok on success" do
      {:ok, rt} = Denox.runtime()
      assert :ok = Denox.exec(rt, "1 + 1")
    end

    test "returns error on failure" do
      {:ok, rt} = Denox.runtime()
      assert {:error, _} = Denox.exec(rt, "throw 'fail'")
    end
  end

  describe "call/3" do
    test "calls a named function with arguments" do
      {:ok, rt} = Denox.runtime()
      Denox.exec(rt, "function add(a, b) { return a + b; }")
      assert {:ok, "5"} = Denox.call(rt, "add", [2, 3])
    end

    test "calls a function with string arguments" do
      {:ok, rt} = Denox.runtime()
      Denox.exec(rt, "function greet(name) { return 'Hello, ' + name + '!'; }")
      assert {:ok, ~s("Hello, Alice!")} = Denox.call(rt, "greet", ["Alice"])
    end

    test "calls a function returning an object" do
      {:ok, rt} = Denox.runtime()
      Denox.exec(rt, "function makeObj(k, v) { return {[k]: v}; }")
      assert {:ok, json} = Denox.call(rt, "makeObj", ["name", "Bob"])
      assert {:ok, %{"name" => "Bob"}} = Jason.decode(json)
    end

    test "returns error for undefined function" do
      {:ok, rt} = Denox.runtime()
      assert {:error, _} = Denox.call(rt, "nonExistent", [1])
    end
  end

  describe "eval_decode/2" do
    test "decodes JSON result to Elixir map" do
      {:ok, rt} = Denox.runtime()
      assert {:ok, %{"a" => 1}} = Denox.eval_decode(rt, "({a: 1})")
    end

    test "decodes arrays" do
      {:ok, rt} = Denox.runtime()
      assert {:ok, [1, 2, 3]} = Denox.eval_decode(rt, "[1, 2, 3]")
    end

    test "decodes numbers" do
      {:ok, rt} = Denox.runtime()
      assert {:ok, 42} = Denox.eval_decode(rt, "42")
    end

    test "decodes strings" do
      {:ok, rt} = Denox.runtime()
      assert {:ok, "hello"} = Denox.eval_decode(rt, "'hello'")
    end

    test "propagates eval errors" do
      {:ok, rt} = Denox.runtime()
      assert {:error, _} = Denox.eval_decode(rt, "throw 'err'")
    end
  end

  describe "call_decode/3" do
    test "calls function and decodes result" do
      {:ok, rt} = Denox.runtime()
      Denox.exec(rt, "function double(n) { return n * 2; }")
      assert {:ok, 10} = Denox.call_decode(rt, "double", [5])
    end
  end
end
