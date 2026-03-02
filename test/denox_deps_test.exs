defmodule DenoxDepsTest do
  use ExUnit.Case, async: false

  # All deps tests require deno CLI and are excluded by default.
  # Run with: mix test --include deno
  @moduletag :deno
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    # Create a test deno.json in the tmp dir
    config = Path.join(dir, "deno.json")

    File.write!(config, Jason.encode!(%{"imports" => %{}}))

    %{config: config, tmp_dir: dir}
  end

  describe "check/1" do
    test "returns error when node_modules doesn't exist", %{config: config} do
      assert {:error, msg} = Denox.Deps.check(config: config)
      assert msg =~ "not installed"
    end

    test "returns :ok when node_modules exists", %{tmp_dir: dir, config: config} do
      File.mkdir_p!(Path.join(dir, "node_modules"))
      assert :ok = Denox.Deps.check(config: config)
    end

    test "legacy vendor_dir option still works", %{tmp_dir: dir} do
      vendor_dir = Path.join(dir, "vendor")
      assert {:error, msg} = Denox.Deps.check(vendor_dir: vendor_dir)
      assert msg =~ "not found"

      File.mkdir_p!(vendor_dir)
      assert :ok = Denox.Deps.check(vendor_dir: vendor_dir)
    end
  end

  describe "list/1" do
    test "lists empty imports", %{config: config} do
      assert {:ok, %{}} = Denox.Deps.list(config: config)
    end

    test "lists declared imports", %{config: config} do
      File.write!(
        config,
        Jason.encode!(%{"imports" => %{"zod" => "npm:zod@^3.22"}})
      )

      assert {:ok, %{"zod" => "npm:zod@^3.22"}} = Denox.Deps.list(config: config)
    end

    test "returns error for missing config" do
      assert {:error, _} = Denox.Deps.list(config: "/nonexistent/deno.json")
    end
  end

  describe "add/3 and remove/2" do
    test "adds a dependency to deno.json", %{config: config} do
      assert :ok = Denox.Deps.add("zod", "npm:zod@^3.22", config: config)
      assert {:ok, imports} = Denox.Deps.list(config: config)
      assert Map.has_key?(imports, "zod")
    end

    test "removes a dependency from deno.json", %{config: config} do
      # First add
      File.write!(
        config,
        Jason.encode!(%{"imports" => %{"zod" => "npm:zod@^3.22"}})
      )

      assert :ok = Denox.Deps.remove("zod", config: config)
      assert {:ok, imports} = Denox.Deps.list(config: config)
      refute Map.has_key?(imports, "zod")
    end
  end

  describe "install/1" do
    test "installs dependencies via deno install", %{config: config, tmp_dir: dir} do
      File.write!(
        config,
        Jason.encode!(%{
          "imports" => %{
            "lodash-es/add" => "npm:lodash-es@^4.17/add"
          }
        })
      )

      assert :ok = Denox.Deps.install(config: config)
      assert File.dir?(Path.join(dir, "node_modules"))
    end

    test "sets vendor:true in deno.json", %{config: config} do
      File.write!(
        config,
        Jason.encode!(%{
          "imports" => %{
            "lodash-es/add" => "npm:lodash-es@^4.17/add"
          }
        })
      )

      assert :ok = Denox.Deps.install(config: config)

      {:ok, content} = File.read(config)
      {:ok, json} = Jason.decode(content)
      assert json["vendor"] == true
    end
  end

  describe "runtime/1" do
    test "returns error without install", %{config: config} do
      assert {:error, msg} = Denox.Deps.runtime(config: config)
      assert msg =~ "not installed"
    end
  end
end
