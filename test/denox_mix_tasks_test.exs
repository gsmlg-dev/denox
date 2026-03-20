defmodule DenoxMixTasksTest do
  @moduledoc """
  Tests for Mix tasks that can run without Deno CLI.
  Tests the argument validation and error path behaviors.
  """
  use ExUnit.Case, async: false

  describe "mix denox.add" do
    test "raises when called with wrong number of arguments" do
      Mix.Task.reenable("denox.add")

      assert_raise Mix.Error, ~r/Usage: mix denox.add/, fn ->
        Mix.Task.run("denox.add", [])
      end
    end

    test "raises when called with only one argument" do
      Mix.Task.reenable("denox.add")

      assert_raise Mix.Error, ~r/Usage: mix denox.add/, fn ->
        Mix.Task.run("denox.add", ["zod"])
      end
    end
  end

  describe "mix denox.remove" do
    test "raises when called with no arguments" do
      Mix.Task.reenable("denox.remove")

      assert_raise Mix.Error, ~r/Usage: mix denox.remove/, fn ->
        Mix.Task.run("denox.remove", [])
      end
    end
  end

  describe "mix denox.install" do
    test "raises when deno.json does not exist and Deno CLI is not configured" do
      original = Application.get_env(:denox, :cli)

      on_exit(fn ->
        if original,
          do: Application.put_env(:denox, :cli, original),
          else: Application.delete_env(:denox, :cli)
      end)

      Application.delete_env(:denox, :cli)

      # Without Deno CLI configured, install fails finding deno
      # (find_deno fails → install returns error → Mix.raise)
      unless System.find_executable("deno") do
        assert_raise Mix.Error, fn ->
          Mix.Task.run("denox.install", ["--config", "/nonexistent/deno.json"])
        end
      end
    end
  end
end
