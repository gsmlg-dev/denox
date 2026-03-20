defmodule DenoxFileTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  describe "eval_file/2" do
    test "evaluates a JavaScript file", %{tmp_dir: dir} do
      path = Path.join(dir, "test.js")
      File.write!(path, "1 + 2 + 3")
      {:ok, rt} = Denox.runtime()
      assert {:ok, "6"} = Denox.eval_file(rt, path)
    end

    test "evaluates a TypeScript file with auto-transpilation", %{tmp_dir: dir} do
      path = Path.join(dir, "test.ts")
      File.write!(path, "const x: number = 42; x")
      {:ok, rt} = Denox.runtime()
      assert {:ok, "42"} = Denox.eval_file(rt, path)
    end

    test "evaluates .tsx files", %{tmp_dir: dir} do
      path = Path.join(dir, "test.tsx")
      File.write!(path, "const msg: string = 'hello'; msg")
      {:ok, rt} = Denox.runtime()
      assert {:ok, ~s("hello")} = Denox.eval_file(rt, path)
    end

    test "returns error for missing file" do
      {:ok, rt} = Denox.runtime()
      assert {:error, msg} = Denox.eval_file(rt, "/nonexistent/file.js")
      assert msg =~ "Failed to read"
    end

    test "returns error for syntax errors", %{tmp_dir: dir} do
      path = Path.join(dir, "bad.js")
      File.write!(path, "function {{{")
      {:ok, rt} = Denox.runtime()
      assert {:error, _} = Denox.eval_file(rt, path)
    end

    test "explicit transpile option", %{tmp_dir: dir} do
      path = Path.join(dir, "code.txt")
      File.write!(path, "const x: number = 42; x")
      {:ok, rt} = Denox.runtime()
      # .txt won't auto-transpile, so use explicit option
      assert {:ok, "42"} = Denox.eval_file(rt, path, transpile: true)
    end
  end

  describe "eval_file_async/3" do
    test "evaluates a JS file asynchronously (module mode)", %{tmp_dir: dir} do
      path = Path.join(dir, "async_test.js")
      File.write!(path, "export default 1 + 2 + 3")
      {:ok, rt} = Denox.runtime()
      task = Denox.eval_file_async(rt, path)
      assert {:ok, "6"} = Task.await(task)
    end

    test "evaluates a TS file asynchronously (module mode)", %{tmp_dir: dir} do
      path = Path.join(dir, "async_test.ts")
      File.write!(path, "const x: number = 42; export default x")
      {:ok, rt} = Denox.runtime()
      task = Denox.eval_file_async(rt, path)
      assert {:ok, "42"} = Task.await(task)
    end

    test "returns error for missing file" do
      {:ok, rt} = Denox.runtime()
      task = Denox.eval_file_async(rt, "/nonexistent/file.js")
      assert {:error, msg} = Task.await(task)
      assert msg =~ "Failed to read"
    end
  end

  describe "eval_file_decode/3" do
    test "evaluates and decodes JSON result", %{tmp_dir: dir} do
      path = Path.join(dir, "decode_test.js")
      File.write!(path, ~s|({name: "test", value: 42})|)
      {:ok, rt} = Denox.runtime()
      assert {:ok, %{"name" => "test", "value" => 42}} = Denox.eval_file_decode(rt, path)
    end

    test "returns error for missing file" do
      {:ok, rt} = Denox.runtime()
      assert {:error, msg} = Denox.eval_file_decode(rt, "/nonexistent/file.js")
      assert msg =~ "Failed to read"
    end
  end

  describe "eval_file_async_decode/3" do
    test "evaluates asynchronously and decodes result", %{tmp_dir: dir} do
      path = Path.join(dir, "async_decode_test.js")
      File.write!(path, ~s|export default {items: [1, 2, 3]}|)
      {:ok, rt} = Denox.runtime()
      task = Denox.eval_file_async_decode(rt, path)
      assert {:ok, %{"items" => [1, 2, 3]}} = Task.await(task)
    end
  end
end
