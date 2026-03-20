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

  describe "add/3 — success path" do
    test "creates config and adds import entry when config does not exist", %{tmp_dir: dir} do
      config = Path.join(dir, "new_deno.json")
      refute File.exists?(config)

      # add/3 may fail at the `deno install` step, but ensure_config and add_to_config should succeed
      Denox.Deps.add("testpkg", "file:./nonexistent_pkg", config: config)
      # Config file should have been created and updated regardless of deno install result
      assert File.exists?(config)
      {:ok, content} = File.read(config)
      assert content =~ "testpkg"
    end

    test "updates existing config with new import entry", %{tmp_dir: dir} do
      config = Path.join(dir, "deno.json")
      write_json(config, %{"imports" => %{"existing" => "npm:existing@1.0"}})
      Denox.Deps.add("newpkg", "npm:newpkg@^2.0", config: config)
      {:ok, content} = File.read(config)
      assert content =~ "newpkg"
      assert content =~ "existing"
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

  describe "install/1 — default args" do
    test "returns error when deno.json does not exist in CWD" do
      unless File.exists?("deno.json") do
        assert {:error, _} = Denox.Deps.install()
      end
    end
  end

  describe "runtime/1 — default args" do
    test "returns error when deps not installed in CWD" do
      unless File.exists?("deno.json") and File.dir?("node_modules") do
        assert {:error, _} = Denox.Deps.runtime()
      end
    end
  end

  describe "remove/2 — default args" do
    test "returns error when deno.json does not exist in CWD" do
      unless File.exists?("deno.json") do
        assert {:error, _} = Denox.Deps.remove("nonexistent")
      end
    end
  end

  describe "wrap_file_error/2 — error clause" do
    test "returns formatted error when config file is unreadable", %{tmp_dir: dir} do
      config = Path.join(dir, "unreadable.json")
      File.write!(config, ~s({"imports":{}}))
      File.chmod!(config, 0o000)

      on_exit(fn -> File.chmod(config, 0o644) end)

      result = Denox.Deps.list(config: config)
      File.chmod!(config, 0o644)

      assert {:error, msg} = result
      assert msg =~ "Failed to read"
    end
  end

  describe "ensure_vendor_config/1 — error clause" do
    test "returns error when config has invalid JSON", %{tmp_dir: dir} do
      config = Path.join(dir, "invalid.json")
      File.write!(config, "not valid json")

      # install/1 calls find_deno → OK, check_config → OK, ensure_vendor_config → fails
      assert {:error, msg} = Denox.Deps.install(config: config)
      assert msg =~ "Failed to update"
    end
  end

  describe "remove_from_config/2 — success path" do
    test "removes import from config and calls install", %{tmp_dir: dir} do
      config = Path.join(dir, "deno.json")
      write_json(config, %{"imports" => %{"testpkg" => "npm:testpkg@1.0"}})

      # remove_from_config succeeds (lines 248-250), then install(opts) is called (line 119)
      # install may succeed or fail depending on deno, but the above lines are covered
      _result = Denox.Deps.remove("testpkg", config: config)

      # Verify the import was removed from the config file
      {:ok, content} = File.read(config)
      assert content =~ ~s("imports")
      refute content =~ "testpkg"
    end
  end
end
