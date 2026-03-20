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

    test "eval_decode returns Elixir terms", %{pool: pool} do
      assert {:ok, %{"a" => 1}} = Denox.Pool.eval_decode(pool, "({a: 1})")
    end

    test "call invokes function" do
      pool = :"test_pool_call_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Denox.Pool, name: pool, size: 1})
      Denox.Pool.exec(pool, "globalThis.double = (n) => n * 2")
      assert {:ok, "10"} = Denox.Pool.call(pool, "double", [5])
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
end
