defmodule Denox.E2E.ScriptEvalTest do
  use ExUnit.Case, async: true

  @scripts_dir Path.expand("scripts", __DIR__)

  setup do
    {:ok, rt} = Denox.runtime()
    %{rt: rt}
  end

  describe "JavaScript script evaluation" do
    test "arithmetic operations", %{rt: rt} do
      path = Path.join(@scripts_dir, "arithmetic.js")
      assert {:ok, result} = Denox.eval_file_decode(rt, path)

      assert result["sum"] == 6
      assert result["product"] == 20
      assert_in_delta result["division"], 3.3333, 0.001
      assert result["modulo"] == 2
    end

    test "string operations", %{rt: rt} do
      path = Path.join(@scripts_dir, "string_ops.js")
      assert {:ok, result} = Denox.eval_file_decode(rt, path)

      assert result["concat"] == "Hello, World!"
      assert result["upper"] == "HELLO"
      assert result["lower"] == "world"
      assert result["length"] == 5
      assert result["includes"] == true
      assert result["split"] == ["a", "b", "c"]
    end

    test "array operations", %{rt: rt} do
      path = Path.join(@scripts_dir, "array_ops.js")
      assert {:ok, result} = Denox.eval_file_decode(rt, path)

      assert result["map"] == [2, 4, 6, 8, 10]
      assert result["filter"] == [4, 5]
      assert result["reduce"] == 15
      assert result["flat"] == [1, 2, 3, 4]
      assert result["find"] == 3
    end

    test "error handling", %{rt: rt} do
      path = Path.join(@scripts_dir, "error_handling.js")
      assert {:ok, result} = Denox.eval_file_decode(rt, path)

      assert result["normalDivision"] == 5.0
      assert result["caughtError"] == true
    end

    test "JSON processing", %{rt: rt} do
      path = Path.join(@scripts_dir, "json_processing.js")
      assert {:ok, result} = Denox.eval_file_decode(rt, path)

      assert result["count"] == 2
      assert [%{"id" => 1, "value" => "A"}, %{"id" => 2, "value" => "B"}] = result["items"]
    end
  end

  describe "TypeScript script evaluation" do
    test "TypeScript with type annotations", %{rt: rt} do
      path = Path.join(@scripts_dir, "typescript_ops.ts")
      assert {:ok, result} = Denox.eval_file_decode(rt, path)

      assert result["activeNames"] == ["Alice", "Charlie"]
      assert result["totalAge"] == 90
      assert result["count"] == 3
    end
  end

  describe "async script evaluation" do
    test "async operations with Promise.all", %{rt: rt} do
      path = Path.join(@scripts_dir, "async_ops.js")
      task = Denox.eval_file_async(rt, path)
      assert {:ok, json} = Task.await(task, 10_000)
      assert {:ok, result} = Jason.decode(json)

      assert result["sum"] == 6
      assert result["count"] == 3
    end
  end

  describe "script error scenarios" do
    test "eval_file returns error for missing file", %{rt: rt} do
      assert {:error, msg} = Denox.eval_file(rt, "/nonexistent/script.js")
      assert msg =~ "Failed to read"
    end

    test "eval_file returns error for script with runtime error", %{rt: rt} do
      path = Path.join(@scripts_dir, "runtime_error.js")
      File.write!(path, "undefinedVar.prop")

      assert {:error, _msg} = Denox.eval_file(rt, path)
    after
      File.rm(Path.join(@scripts_dir, "runtime_error.js"))
    end

    test "eval_file returns error for script with syntax error", %{rt: rt} do
      path = Path.join(@scripts_dir, "syntax_error.js")
      File.write!(path, "function(")

      assert {:error, _msg} = Denox.eval_file(rt, path)
    after
      File.rm(Path.join(@scripts_dir, "syntax_error.js"))
    end
  end
end
