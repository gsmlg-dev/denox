defmodule DenoxTsTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, rt} = Denox.runtime()
    %{rt: rt}
  end

  describe "eval_ts/2 basic types" do
    test "evaluates typed number", %{rt: rt} do
      assert {:ok, "42"} = Denox.eval_ts(rt, "const x: number = 42; x")
    end

    test "evaluates typed string", %{rt: rt} do
      assert {:ok, ~s("hello")} = Denox.eval_ts(rt, ~s(const s: string = "hello"; s))
    end

    test "evaluates typed boolean", %{rt: rt} do
      assert {:ok, "true"} = Denox.eval_ts(rt, "const b: boolean = true; b")
    end

    test "evaluates typed array", %{rt: rt} do
      assert {:ok, "[1,2,3]"} = Denox.eval_ts(rt, "const arr: number[] = [1, 2, 3]; arr")
    end

    test "evaluates typed object", %{rt: rt} do
      code = """
      const obj: { name: string; age: number } = { name: "Alice", age: 30 };
      obj
      """

      assert {:ok, json} = Denox.eval_ts(rt, code)
      assert {:ok, %{"name" => "Alice", "age" => 30}} = Jason.decode(json)
    end
  end

  describe "eval_ts/2 interfaces and type aliases" do
    test "strips interface declarations", %{rt: rt} do
      code = """
      interface User {
        name: string;
        age: number;
      }
      const user: User = { name: "Bob", age: 25 };
      user
      """

      assert {:ok, json} = Denox.eval_ts(rt, code)
      assert {:ok, %{"name" => "Bob", "age" => 25}} = Jason.decode(json)
    end

    test "strips type aliases", %{rt: rt} do
      code = """
      type Point = { x: number; y: number };
      const p: Point = { x: 10, y: 20 };
      p
      """

      assert {:ok, json} = Denox.eval_ts(rt, code)
      assert {:ok, %{"x" => 10, "y" => 20}} = Jason.decode(json)
    end
  end

  describe "eval_ts/2 generics" do
    test "strips generic type parameters", %{rt: rt} do
      code = """
      function identity<T>(x: T): T { return x; }
      identity<number>(42)
      """

      assert {:ok, "42"} = Denox.eval_ts(rt, code)
    end

    test "generic with multiple type parameters", %{rt: rt} do
      code = """
      function pair<A, B>(a: A, b: B): [A, B] { return [a, b]; }
      pair<string, number>("hello", 42)
      """

      assert {:ok, json} = Denox.eval_ts(rt, code)
      assert {:ok, ["hello", 42]} = Jason.decode(json)
    end
  end

  describe "eval_ts/2 enums" do
    test "evaluates numeric enums", %{rt: rt} do
      code = """
      enum Color { Red, Green, Blue }
      Color.Green
      """

      assert {:ok, "1"} = Denox.eval_ts(rt, code)
    end

    test "evaluates string enums", %{rt: rt} do
      code = """
      enum Direction {
        Up = "UP",
        Down = "DOWN",
      }
      Direction.Up
      """

      assert {:ok, ~s("UP")} = Denox.eval_ts(rt, code)
    end
  end

  describe "eval_ts/2 optional chaining and nullish coalescing" do
    test "optional chaining", %{rt: rt} do
      code = """
      const obj: { a?: { b?: number } } = { a: { b: 42 } };
      obj.a?.b
      """

      assert {:ok, "42"} = Denox.eval_ts(rt, code)
    end

    test "nullish coalescing", %{rt: rt} do
      code = """
      const val: number | null = null;
      val ?? 99
      """

      assert {:ok, "99"} = Denox.eval_ts(rt, code)
    end
  end

  describe "eval_ts/2 error handling" do
    test "returns error for TS syntax errors", %{rt: rt} do
      assert {:error, msg} = Denox.eval_ts(rt, "const x: number = ;")
      assert msg =~ "Transpile parse error" or msg =~ "error"
    end

    test "type errors transpile fine (transpile-only, no type-checking)", %{rt: rt} do
      # Assigning a number to a string type should NOT error — transpile strips types
      assert {:ok, "42"} = Denox.eval_ts(rt, "const x: string = 42; x")
    end
  end

  describe "exec_ts/2" do
    test "executes TypeScript, ignores return value", %{rt: rt} do
      assert :ok = Denox.exec_ts(rt, "const x: number = 1;")
    end

    test "returns error on TS parse failure", %{rt: rt} do
      assert {:error, _} = Denox.exec_ts(rt, "const x: = ;")
    end
  end

  describe "eval_ts_decode/2" do
    test "evaluates TS and decodes result", %{rt: rt} do
      code = """
      interface Result { value: number; ok: boolean }
      const r: Result = { value: 42, ok: true };
      r
      """

      assert {:ok, %{"value" => 42, "ok" => true}} = Denox.eval_ts_decode(rt, code)
    end

    test "decodes arrays with typed elements", %{rt: rt} do
      assert {:ok, [1, 2, 3]} = Denox.eval_ts_decode(rt, "const xs: number[] = [1,2,3]; xs")
    end
  end

  describe "eval_ts/2 advanced" do
    test "arrow functions with type annotations", %{rt: rt} do
      code = """
      const add = (a: number, b: number): number => a + b;
      add(3, 4)
      """

      assert {:ok, "7"} = Denox.eval_ts(rt, code)
    end

    test "as-const assertions", %{rt: rt} do
      code = """
      const config = { port: 3000, host: "localhost" } as const;
      config.port
      """

      assert {:ok, "3000"} = Denox.eval_ts(rt, code)
    end

    test "type assertion (as)", %{rt: rt} do
      code = """
      const val: unknown = 42;
      (val as number) + 1
      """

      assert {:ok, "43"} = Denox.eval_ts(rt, code)
    end

    test "satisfies operator", %{rt: rt} do
      code = """
      type Colors = "red" | "green" | "blue";
      const color = "red" satisfies Colors;
      color
      """

      assert {:ok, ~s("red")} = Denox.eval_ts(rt, code)
    end
  end
end
