defmodule DenoxDepsUnitTest do
  @moduledoc """
  Unit tests for Denox.Deps that do not require the Deno CLI.

  These tests cover file I/O, JSON parsing, and check logic.
  Tests that require `deno` are in denox_deps_test.exs (tagged :deno).
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  defp write_json(path, data) do
    File.write!(path, JSON.encode!(data))
  end

  describe "check/1 — vendor_dir legacy option" do
    test "returns error when vendor_dir does not exist", %{tmp_dir: dir} do
      vendor_dir = Path.join(dir, "vendor")
      assert {:error, msg} = Denox.Deps.check(vendor_dir: vendor_dir)
      assert msg =~ "not found"
    end

    test "returns :ok when vendor_dir exists", %{tmp_dir: dir} do
      vendor_dir = Path.join(dir, "vendor")
      File.mkdir_p!(vendor_dir)
      assert :ok = Denox.Deps.check(vendor_dir: vendor_dir)
    end
  end

  describe "check/1 — node_modules (default)" do
    test "returns error when node_modules does not exist", %{tmp_dir: dir} do
      config = Path.join(dir, "deno.json")
      write_json(config, %{"imports" => %{}})
      assert {:error, msg} = Denox.Deps.check(config: config)
      assert msg =~ "not installed"
    end

    test "returns :ok when node_modules exists", %{tmp_dir: dir} do
      config = Path.join(dir, "deno.json")
      write_json(config, %{"imports" => %{}})
      File.mkdir_p!(Path.join(dir, "node_modules"))
      assert :ok = Denox.Deps.check(config: config)
    end
  end

  describe "list/1" do
    test "lists empty imports from deno.json", %{tmp_dir: dir} do
      config = Path.join(dir, "deno.json")
      write_json(config, %{"imports" => %{}})
      assert {:ok, %{}} = Denox.Deps.list(config: config)
    end

    test "lists declared imports", %{tmp_dir: dir} do
      config = Path.join(dir, "deno.json")
      write_json(config, %{"imports" => %{"zod" => "npm:zod@^3.22"}})
      assert {:ok, %{"zod" => "npm:zod@^3.22"}} = Denox.Deps.list(config: config)
    end

    test "returns empty map when no imports key", %{tmp_dir: dir} do
      config = Path.join(dir, "deno.json")
      write_json(config, %{"tasks" => %{}})
      assert {:ok, %{}} = Denox.Deps.list(config: config)
    end

    test "returns error when config file does not exist" do
      assert {:error, msg} = Denox.Deps.list(config: "/nonexistent/path/deno.json")
      assert msg =~ "not found"
    end

    test "returns error when config is invalid JSON", %{tmp_dir: dir} do
      config = Path.join(dir, "deno.json")
      File.write!(config, "not json")
      assert {:error, msg} = Denox.Deps.list(config: config)
      assert msg =~ "Failed to parse"
    end
  end

  describe "runtime/1 error path" do
    test "returns error when deps not installed (no node_modules)", %{tmp_dir: dir} do
      config = Path.join(dir, "deno.json")
      write_json(config, %{"imports" => %{}})
      assert {:error, msg} = Denox.Deps.runtime(config: config)
      assert msg =~ "not installed"
    end

    test "returns {:ok, runtime} when node_modules exists", %{tmp_dir: dir} do
      config = Path.join(dir, "deno.json")
      write_json(config, %{"imports" => %{}})
      File.mkdir_p!(Path.join(dir, "node_modules"))
      assert {:ok, _rt} = Denox.Deps.runtime(config: config)
    end

    test "passes import_map to runtime when provided", %{tmp_dir: dir} do
      config = Path.join(dir, "deno.json")
      write_json(config, %{"imports" => %{}})
      File.mkdir_p!(Path.join(dir, "node_modules"))
      assert {:ok, _rt} = Denox.Deps.runtime(config: config, import_map: %{"foo" => "bar"})
    end
  end

  describe "add/3 — error paths" do
    test "returns error when config has invalid JSON", %{tmp_dir: dir} do
      config = Path.join(dir, "deno.json")
      File.write!(config, "not json")

      # find_deno succeeds (system deno on PATH), ensure_config skips (file exists),
      # add_to_config fails on JSON decode → {:error, "Failed to update..."}
      assert {:error, msg} = Denox.Deps.add("zod", "npm:zod@^3.22", config: config)
      assert msg =~ "Failed to update"
    end

    test "returns error when config path is in non-existent directory" do
      # find_deno succeeds, ensure_config fails writing to nonexistent dir
      assert {:error, msg} =
               Denox.Deps.add("zod", "npm:zod@^3.22", config: "/nonexistent_deps_dir/deno.json")

      assert is_binary(msg)
    end
  end

  describe "remove/2 — error paths" do
    test "returns error when config has invalid JSON", %{tmp_dir: dir} do
      config = Path.join(dir, "deno.json")
      File.write!(config, "not json")

      # find_deno succeeds, check_config passes (file exists),
      # remove_from_config fails JSON decode → {:error, "Failed to update..."}
      assert {:error, msg} = Denox.Deps.remove("zod", config: config)
      assert msg =~ "Failed to update"
    end

    test "returns error when config does not exist" do
      assert {:error, msg} = Denox.Deps.remove("zod", config: "/nonexistent/deno.json")
      assert msg =~ "not found"
    end
  end

  describe "check/1 — default args" do
    test "returns error when called with no args and deno.json does not exist" do
      # Tests the 0-arg default clause; assumes "deno.json" doesn't exist in CWD
      unless File.exists?("deno.json") do
        assert {:error, _} = Denox.Deps.check()
      end
    end
  end

  describe "list/1 — default args" do
    test "returns error when called with no args and deno.json does not exist" do
      unless File.exists?("deno.json") do
        assert {:error, _} = Denox.Deps.list()
      end
    end
  end
end
