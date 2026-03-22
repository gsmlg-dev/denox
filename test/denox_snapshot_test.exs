defmodule DenoxSnapshotTest do
  use ExUnit.Case, async: true

  describe "create_snapshot/2" do
    test "creates a snapshot from JavaScript setup code" do
      assert {:ok, snapshot} = Denox.create_snapshot("globalThis.x = 42")
      assert is_binary(snapshot)
      assert byte_size(snapshot) > 0
    end

    test "creates a snapshot with a function" do
      assert {:ok, snapshot} = Denox.create_snapshot("globalThis.double = (n) => n * 2")
      assert is_binary(snapshot)
    end

    test "creates a snapshot from TypeScript code with transpile option" do
      assert {:ok, snapshot} =
               Denox.create_snapshot(
                 "globalThis.greet = (name: string): string => `Hello, ${name}!`",
                 transpile: true
               )

      assert is_binary(snapshot)
    end

    test "returns error for invalid JavaScript" do
      assert {:error, msg} = Denox.create_snapshot("this is not valid {{{ javascript")
      assert is_binary(msg)
    end
  end

  # NOTE: Custom V8 snapshots are not compatible with MainWorker's internal
  # snapshot. MainWorker uses its own snapshot for bootstrapping the Deno runtime
  # environment. The snapshot parameter is accepted for API compatibility but
  # currently ignored. Use eval() to run initialization code instead.
  describe "runtime with snapshot" do
    @tag :skip
    test "snapshot state is available in runtime" do
      {:ok, snapshot} = Denox.create_snapshot("globalThis.x = 42")
      {:ok, rt} = Denox.runtime(snapshot: snapshot)
      assert {:ok, "42"} = Denox.eval(rt, "x")
    end

    @tag :skip
    test "snapshot function is callable" do
      {:ok, snapshot} = Denox.create_snapshot("globalThis.double = (n) => n * 2")
      {:ok, rt} = Denox.runtime(snapshot: snapshot)
      assert {:ok, "10"} = Denox.call(rt, "double", [5])
    end

    @tag :skip
    test "snapshot with multiple globals" do
      setup = """
      globalThis.add = (a, b) => a + b;
      globalThis.greeting = "hello";
      globalThis.config = { debug: true, version: 1 };
      """

      {:ok, snapshot} = Denox.create_snapshot(setup)
      {:ok, rt} = Denox.runtime(snapshot: snapshot)

      assert {:ok, "7"} = Denox.call(rt, "add", [3, 4])
      assert {:ok, "\"hello\""} = Denox.eval(rt, "greeting")
      assert {:ok, result} = Denox.eval_decode(rt, "config")
      assert result == %{"debug" => true, "version" => 1}
    end

    @tag :skip
    test "snapshot state can be extended at runtime" do
      {:ok, snapshot} = Denox.create_snapshot("globalThis.base = 10")
      {:ok, rt} = Denox.runtime(snapshot: snapshot)

      :ok = Denox.exec(rt, "globalThis.derived = base * 2")
      assert {:ok, "20"} = Denox.eval(rt, "derived")
    end

    @tag :skip
    test "same snapshot can create multiple independent runtimes" do
      {:ok, snapshot} = Denox.create_snapshot("globalThis.counter = 0")
      {:ok, rt1} = Denox.runtime(snapshot: snapshot)
      {:ok, rt2} = Denox.runtime(snapshot: snapshot)

      :ok = Denox.exec(rt1, "counter += 10")
      :ok = Denox.exec(rt2, "counter += 20")

      assert {:ok, "10"} = Denox.eval(rt1, "counter")
      assert {:ok, "20"} = Denox.eval(rt2, "counter")
    end

    test "runtime without snapshot still works" do
      {:ok, rt} = Denox.runtime()
      assert {:ok, "3"} = Denox.eval(rt, "1 + 2")
    end

    test "passing non-empty snapshot emits a warning (MainWorker incompatibility)" do
      {:ok, snapshot} = Denox.create_snapshot("globalThis.x = 42")

      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          {:ok, _rt} = Denox.runtime(snapshot: snapshot)
        end)

      assert warning =~ "snapshot"
      assert warning =~ "not supported"
    end

    @tag :skip
    test "TypeScript snapshot with transpile option" do
      {:ok, snapshot} =
        Denox.create_snapshot(
          "globalThis.multiply = (a: number, b: number): number => a * b",
          transpile: true
        )

      {:ok, rt} = Denox.runtime(snapshot: snapshot)
      assert {:ok, "15"} = Denox.call(rt, "multiply", [3, 5])
    end
  end
end
