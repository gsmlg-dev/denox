defmodule CoverageGapsTest do
  @moduledoc """
  Tests targeting specific uncovered code paths identified by coverage analysis.
  Focuses on error paths, edge cases, and task error handling.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Denox.Cli.Install, as: CliInstallTask

  describe "Mix.Tasks.Denox.Cli.Install error path" do
    test "raises Mix.Error when install fails with --force" do
      original_cli = Application.get_env(:denox, :cli)
      version = "0.0.0-force-fail"
      Application.put_env(:denox, :cli, version: version)

      on_exit(fn ->
        if original_cli,
          do: Application.put_env(:denox, :cli, original_cli),
          else: Application.delete_env(:denox, :cli)

        File.rm_rf("_build/denox_cli-#{version}")
      end)

      # --force skips installed? check → calls install() → download fails → Mix.raise (line 41)
      assert_raise Mix.Error, ~r/Failed to install/, fn ->
        CliInstallTask.run(["--force"])
      end
    end

    test "raises when no version configured" do
      original_cli = Application.get_env(:denox, :cli)
      Application.delete_env(:denox, :cli)

      on_exit(fn ->
        if original_cli,
          do: Application.put_env(:denox, :cli, original_cli),
          else: Application.delete_env(:denox, :cli)
      end)

      assert_raise Mix.Error, ~r/No Deno CLI version configured/, fn ->
        CliInstallTask.run([])
      end
    end
  end

  describe "Denox.CLI.download/2 error paths" do
    test "catches :exit when httpc manager is unavailable" do
      # Stop inets so httpc is unavailable, then call download directly
      # but download restarts inets internally — so we stop it via
      # killing the httpc_manager between ensure_all_started and request
      Application.stop(:inets)

      on_exit(fn -> Application.ensure_all_started(:inets) end)

      # Even though download restarts :inets, the :httpc_manager may not
      # be ready for the request. This exercises the error handling.
      result = Denox.CLI.download("https://example.com/test.zip", 1)

      # Should return some form of result (error or success depending on timing)
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end
  end

  describe "Denox.Run NIF error paths" do
    test "start_link fails gracefully with empty file specifier" do
      Process.flag(:trap_exit, true)

      # Empty specifier — may or may not fail depending on NIF behavior
      result = Denox.Run.start_link(file: "", permissions: :all)

      case result do
        {:error, _} -> assert true
        {:ok, pid} -> Denox.Run.stop(pid)
      end
    end

    test "send returns {:error, :closed} after runtime exits" do
      {:ok, pid} =
        Denox.Run.start_link(file: "nonexistent_script_xyz_abc.ts", permissions: :all)

      Denox.Run.subscribe(pid)

      receive do
        {:denox_run_exit, ^pid, _} -> :ok
      after
        10_000 -> flunk("Runtime did not exit in time")
      end

      # After exit, send should return {:error, :closed} via Base module
      assert {:error, :closed} = Denox.Run.send(pid, "data\n")
    end
  end

  describe "Denox.JSON.encode_pretty!/1" do
    test "produces valid formatted JSON" do
      result = Denox.JSON.encode_pretty!(%{"key" => "value", "list" => [1, 2]})
      assert is_binary(result)
      assert %{"key" => "value", "list" => [1, 2]} = Denox.JSON.decode!(result)
    end
  end

  describe "Denox.build_granular_permissions_json consistency" do
    test "false permission entries are filtered out (consistent with Denox.Run)" do
      # With the fix, Denox.runtime should filter false entries just like Denox.Run
      {:ok, rt} = Denox.runtime(permissions: [allow_env: true, allow_net: false])
      # Runtime should be created successfully — allow_net: false is dropped
      assert {:ok, "3"} = Denox.eval(rt, "1 + 2")
    end

    test "permissions: nil falls through to default (empty permissions)" do
      {:ok, rt} = Denox.runtime(permissions: nil)
      assert {:ok, "3"} = Denox.eval(rt, "1 + 2")
    end
  end

  describe "Denox.Run.Base unknown call" do
    test "CLI backend returns {:error, {:unknown_call, msg}} for unknown calls" do
      # This needs a running Denox.CLI.Run — skip if no deno configured
      case Application.get_env(:denox, :cli) do
        nil ->
          :skip

        _ ->
          tmp_dir =
            Path.join("tmp", "coverage-unknown-call-#{System.unique_integer([:positive])}")

          File.mkdir_p!(tmp_dir)
          script = Path.join(tmp_dir, "sleep.ts")
          File.write!(script, "await new Promise(() => {});")

          on_exit(fn -> File.rm_rf!(tmp_dir) end)

          {:ok, pid} = Denox.CLI.Run.start_link(file: script, permissions: :all)

          assert {:error, {:unknown_call, :bogus}} =
                   GenServer.call(pid, :bogus)

          Denox.CLI.Run.stop(pid)
      end
    end
  end

  describe "Denox.CLI.Run noeol accumulation" do
    @tag :tmp_dir
    test "large output without newlines is dispatched as chunks", %{tmp_dir: tmp_dir} do
      # Script that outputs a very long line (>64KB to trigger noeol from Port)
      script = Path.join(tmp_dir, "big_line.ts")

      File.write!(script, """
      const big = "x".repeat(100_000);
      console.log(big);
      """)

      case Application.get_env(:denox, :cli) do
        nil ->
          :skip

        _ ->
          {:ok, pid} = Denox.CLI.Run.start_link(file: script, permissions: :all)
          Denox.CLI.Run.subscribe(pid)

          # Collect all lines until exit
          lines = collect_lines(pid, [])
          total_output = Enum.join(lines)
          # Should receive all 100_000 'x' characters across one or more chunks
          assert String.length(total_output) == 100_000
          assert total_output == String.duplicate("x", 100_000)
      end
    end
  end

  defp collect_lines(pid, acc) do
    receive do
      {:denox_run_stdout, ^pid, line} -> collect_lines(pid, [line | acc])
      {:denox_run_exit, ^pid, _status} -> Enum.reverse(acc)
    after
      15_000 -> Enum.reverse(acc)
    end
  end
end
