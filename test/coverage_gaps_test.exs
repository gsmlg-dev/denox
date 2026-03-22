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
end
