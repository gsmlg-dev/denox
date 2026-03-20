defmodule DenoxPoolTest do
  use ExUnit.Case, async: true

  describe "pool lifecycle" do
    test "starts a pool with default size" do
      start_supervised!({Denox.Pool, name: :test_pool_default, size: 2})
      assert Denox.Pool.size(:test_pool_default) == 2
    end

    test "starts a pool with custom size" do
      start_supervised!({Denox.Pool, name: :test_pool_custom, size: 4})
      assert Denox.Pool.size(:test_pool_custom) == 4
    end
  end

  describe "pool eval" do
    setup do
      pool = :"test_pool_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Denox.Pool, name: pool, size: 2})
      %{pool: pool}
    end

    test "eval returns correct result", %{pool: pool} do
      assert {:ok, "3"} = Denox.Pool.eval(pool, "1 + 2")
    end

    test "eval_ts transpiles and evaluates", %{pool: pool} do
      assert {:ok, "42"} = Denox.Pool.eval_ts(pool, "const x: number = 42; x")
    end

    test "eval_async resolves promises", %{pool: pool} do
      assert {:ok, "99"} =
               Task.await(Denox.Pool.eval_async(pool, "export default await Promise.resolve(99)"))
    end

    test "exec ignores return value", %{pool: pool} do
      assert :ok = Denox.Pool.exec(pool, "1 + 1")
    end

    test "exec_ts ignores return value of TypeScript", %{pool: pool} do
      assert :ok = Denox.Pool.exec_ts(pool, "const x: number = 1 + 1; x")
    end

    test "eval_decode returns Elixir terms", %{pool: pool} do
      assert {:ok, %{"a" => 1}} = Denox.Pool.eval_decode(pool, "({a: 1})")
    end

    test "eval_ts_decode transpiles and decodes", %{pool: pool} do
      assert {:ok, %{"x" => 42}} =
               Denox.Pool.eval_ts_decode(pool, "const x: number = 42; ({x})")
    end

    test "call_decode invokes function and decodes result" do
      pool = :"test_pool_cd_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Denox.Pool, name: pool, size: 1})
      Denox.Pool.exec(pool, "globalThis.getObj = () => ({status: 'ok', count: 3})")
      assert {:ok, %{"status" => "ok", "count" => 3}} = Denox.Pool.call_decode(pool, "getObj")
    end

    test "call_async_decode invokes async function and decodes result" do
      pool = :"test_pool_cad_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Denox.Pool, name: pool, size: 1})
      Denox.Pool.exec(pool, "globalThis.asyncDouble = async (n) => n * 2")
      assert {:ok, 84} = Denox.Pool.call_async_decode(pool, "asyncDouble", [42]) |> Task.await()
    end

    test "call invokes function" do
      pool = :"test_pool_call_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Denox.Pool, name: pool, size: 1})
      Denox.Pool.exec(pool, "globalThis.double = (n) => n * 2")
      assert {:ok, "10"} = Denox.Pool.call(pool, "double", [5])
    end

    test "call invokes function with default empty args" do
      pool = :"test_pool_call_noargs_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Denox.Pool, name: pool, size: 1})
      Denox.Pool.exec(pool, "globalThis.greet = () => 'hello'")
      assert {:ok, "\"hello\""} = Denox.Pool.call(pool, "greet")
    end

    test "call_async invokes function with default empty args" do
      pool = :"test_pool_ca_noargs_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Denox.Pool, name: pool, size: 1})
      Denox.Pool.exec(pool, "globalThis.ping = async () => 'pong'")
      assert {:ok, "\"pong\""} = Task.await(Denox.Pool.call_async(pool, "ping"))
    end

    test "call_async_decode invokes function with default empty args" do
      pool = :"test_pool_cad_noargs_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Denox.Pool, name: pool, size: 1})
      Denox.Pool.exec(pool, "globalThis.count = async () => 42")
      assert {:ok, 42} = Task.await(Denox.Pool.call_async_decode(pool, "count"))
    end

    test "eval_async_decode evaluates and decodes", %{pool: pool} do
      assert {:ok, %{"x" => 1}} =
               Denox.Pool.eval_async_decode(pool, "export default {x: 1}") |> Task.await()
    end

    test "eval_ts_async_decode transpiles and decodes", %{pool: pool} do
      code = "interface R { v: number }; const r: R = {v: 7}; export default r"
      assert {:ok, %{"v" => 7}} = Denox.Pool.eval_ts_async_decode(pool, code) |> Task.await()
    end

    test "eval_ts_async transpiles and resolves", %{pool: pool} do
      code = "const x: number = 77; export default await Promise.resolve(x)"

      assert {:ok, "77"} = Task.await(Denox.Pool.eval_ts_async(pool, code))
    end

    test "call_async invokes async function" do
      pool = :"test_pool_call_async_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Denox.Pool, name: pool, size: 1})
      Denox.Pool.exec(pool, "globalThis.asyncTriple = async (n) => n * 3")
      assert {:ok, "15"} = Task.await(Denox.Pool.call_async(pool, "asyncTriple", [5]))
    end
  end

  describe "pool eval_file" do
    @tag :tmp_dir
    test "evaluates a file from pool", %{tmp_dir: dir} do
      pool = :"test_pool_file_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Denox.Pool, name: pool, size: 1})

      path = Path.join(dir, "pool_test.js")
      File.write!(path, "1 + 2 + 3")
      assert {:ok, "6"} = Denox.Pool.eval_file(pool, path)
    end

    @tag :tmp_dir
    test "eval_file_decode evaluates and decodes result", %{tmp_dir: dir} do
      pool = :"test_pool_file_decode_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Denox.Pool, name: pool, size: 1})

      path = Path.join(dir, "data.js")
      File.write!(path, "({answer: 42})")
      assert {:ok, %{"answer" => 42}} = Denox.Pool.eval_file_decode(pool, path)
    end
  end

  describe "pool eval_file_async" do
    @tag :tmp_dir
    test "evaluates a file asynchronously from pool", %{tmp_dir: dir} do
      pool = :"test_pool_file_async_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Denox.Pool, name: pool, size: 1})

      path = Path.join(dir, "async_test.js")
      File.write!(path, "export default await Promise.resolve(99)")
      assert {:ok, "99"} = Task.await(Denox.Pool.eval_file_async(pool, path))
    end

    @tag :tmp_dir
    test "eval_file_async_decode evaluates and decodes result", %{tmp_dir: dir} do
      pool = :"test_pool_file_async_decode_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Denox.Pool, name: pool, size: 1})

      path = Path.join(dir, "async_data.js")
      File.write!(path, "export default await Promise.resolve([1, 2, 3])")
      assert {:ok, [1, 2, 3]} = Task.await(Denox.Pool.eval_file_async_decode(pool, path))
    end

    test "eval_file_async returns error for missing file" do
      pool = :"test_pool_fa_err_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Denox.Pool, name: pool, size: 1})

      assert {:error, msg} = Task.await(Denox.Pool.eval_file_async(pool, "/nonexistent.js"))
      assert msg =~ "Failed to read"
    end

    test "eval_file_async_decode returns error for missing file" do
      pool = :"test_pool_fad_err_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Denox.Pool, name: pool, size: 1})

      assert {:error, msg} =
               Task.await(Denox.Pool.eval_file_async_decode(pool, "/nonexistent.js"))

      assert msg =~ "Failed to read"
    end
  end

  describe "pool load_npm" do
    @tag :tmp_dir
    test "loads bundled JS into all pool runtimes", %{tmp_dir: dir} do
      pool = :"test_pool_npm_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Denox.Pool, name: pool, size: 2})

      bundle_path = Path.join(dir, "bundle.js")
      File.write!(bundle_path, "globalThis.bundleLoaded = true;")

      assert :ok = Denox.Pool.load_npm(pool, bundle_path)

      # Both runtimes should have the global set
      assert {:ok, "true"} = Denox.Pool.eval(pool, "globalThis.bundleLoaded")
      assert {:ok, "true"} = Denox.Pool.eval(pool, "globalThis.bundleLoaded")
    end

    test "returns error for missing bundle" do
      pool = :"test_pool_npm_err_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Denox.Pool, name: pool, size: 1})

      assert {:error, msg} = Denox.Pool.load_npm(pool, "/nonexistent/bundle.js")
      assert msg =~ "Failed to read bundle"
    end

    @tag :tmp_dir
    test "returns error when bundle JS throws on exec", %{tmp_dir: dir} do
      pool = :"test_pool_npm_exec_err_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Denox.Pool, name: pool, size: 1})

      bundle_path = Path.join(dir, "bad_bundle.js")
      File.write!(bundle_path, "throw new Error('bundle failed');")

      assert {:error, _msg} = Denox.Pool.load_npm(pool, bundle_path)
    end
  end

  describe "pool round-robin" do
    test "distributes requests across runtimes" do
      pool = :"test_pool_rr_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Denox.Pool, name: pool, size: 2})

      # Set state in runtime 0 (index 0 → first call)
      Denox.Pool.exec(pool, "globalThis.id = 'A'")
      # Set state in runtime 1 (index 1 → second call)
      Denox.Pool.exec(pool, "globalThis.id = 'B'")

      # Third call goes to runtime 0 again
      assert {:ok, ~s("A")} = Denox.Pool.eval(pool, "globalThis.id")
      # Fourth call goes to runtime 1
      assert {:ok, ~s("B")} = Denox.Pool.eval(pool, "globalThis.id")
    end
  end

  describe "pool concurrent access" do
    test "handles concurrent requests" do
      pool = :"test_pool_conc_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Denox.Pool, name: pool, size: 4})

      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            {:ok, result} = Denox.Pool.eval(pool, "#{i} * 2")
            String.to_integer(result)
          end)
        end

      results = Task.await_many(tasks)
      expected = for i <- 1..20, do: i * 2
      assert Enum.sort(results) == Enum.sort(expected)
    end
  end

  describe "pool error handling" do
    setup do
      pool = :"test_pool_err_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Denox.Pool, name: pool, size: 2})
      %{pool: pool}
    end

    test "eval returns error for invalid JavaScript", %{pool: pool} do
      assert {:error, msg} = Denox.Pool.eval(pool, "this is not valid {{{")
      assert is_binary(msg)
    end

    test "pool remains usable after eval error", %{pool: pool} do
      assert {:error, _} = Denox.Pool.eval(pool, "throw new Error('boom')")
      assert {:ok, "42"} = Denox.Pool.eval(pool, "42")
    end

    test "eval_decode returns error for non-serializable result", %{pool: pool} do
      assert {:error, _} = Denox.Pool.eval_decode(pool, "throw new Error('decode fail')")
    end
  end
end
