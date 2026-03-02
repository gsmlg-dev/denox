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
end
