defmodule Denox.CallbackTest do
  use ExUnit.Case, async: true

  alias Denox.CallbackHandler

  describe "basic callbacks" do
    test "JS can call a simple Elixir callback" do
      {:ok, rt, _handler} =
        CallbackHandler.runtime(
          callbacks: %{
            "greet" => fn [name] -> "Hello, #{name}!" end
          }
        )

      {:ok, result} = Denox.eval(rt, ~s[Denox.callback("greet", "Alice")])
      assert result == ~s("Hello, Alice!")
    end

    test "JS can call a numeric callback" do
      {:ok, rt, _handler} =
        CallbackHandler.runtime(
          callbacks: %{
            "add" => fn [a, b] -> a + b end
          }
        )

      {:ok, result} = Denox.eval(rt, ~s[Denox.callback("add", 10, 20)])
      assert result == "30"
    end

    test "callback returns complex object" do
      {:ok, rt, _handler} =
        CallbackHandler.runtime(
          callbacks: %{
            "get_user" => fn [id] -> %{"id" => id, "name" => "User #{id}"} end
          }
        )

      {:ok, result} = Denox.eval(rt, ~s[Denox.callback("get_user", 42)])
      decoded = Jason.decode!(result)
      assert decoded == %{"id" => 42, "name" => "User 42"}
    end

    test "multiple callbacks in one eval" do
      {:ok, rt, _handler} =
        CallbackHandler.runtime(
          callbacks: %{
            "double" => fn [x] -> x * 2 end,
            "add_one" => fn [x] -> x + 1 end
          }
        )

      code = """
      const a = Denox.callback("double", 5);
      const b = Denox.callback("add_one", a);
      b
      """

      {:ok, result} = Denox.eval(rt, code)
      # double(5) = 10, add_one(10) = 11
      assert result == "11"
    end
  end

  describe "callback error handling" do
    test "unknown callback name returns error" do
      {:ok, rt, _handler} =
        CallbackHandler.runtime(callbacks: %{"known" => fn _ -> :ok end})

      {:error, msg} = Denox.eval(rt, ~s[Denox.callback("unknown_fn")])
      assert msg =~ "Unknown callback"
    end

    test "callback that raises returns error" do
      {:ok, rt, _handler} =
        CallbackHandler.runtime(
          callbacks: %{
            "fail" => fn _ -> raise "intentional error" end
          }
        )

      {:error, msg} = Denox.eval(rt, ~s[Denox.callback("fail")])
      assert msg =~ "intentional error"
    end
  end

  describe "callbacks with eval_async" do
    test "callbacks work in async eval context" do
      {:ok, rt, _handler} =
        CallbackHandler.runtime(
          callbacks: %{
            "multiply" => fn [a, b] -> a * b end
          }
        )

      {:ok, result} =
        Task.await(Denox.eval_async(rt, ~s[return Denox.callback("multiply", 6, 7)]))

      assert result == "42"
    end
  end

  describe "callbacks with TypeScript" do
    test "callbacks work with eval_ts" do
      {:ok, rt, _handler} =
        CallbackHandler.runtime(
          callbacks: %{
            "length" => fn [s] -> String.length(s) end
          }
        )

      code = """
      const len: number = Denox.callback("length", "hello");
      len
      """

      {:ok, result} = Denox.eval_ts(rt, code)
      assert result == "5"
    end
  end

  describe "runtime without callbacks" do
    test "runtime without callback_pid works normally" do
      {:ok, rt} = Denox.runtime()
      {:ok, result} = Denox.eval(rt, "1 + 2")
      assert result == "3"
    end

    test "Denox global is not defined without callback handler" do
      {:ok, rt} = Denox.runtime()
      {:ok, result} = Denox.eval(rt, ~s[typeof Denox])
      assert result == ~s("undefined")
    end
  end
end
