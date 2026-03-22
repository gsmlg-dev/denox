defmodule Denox.Run.BaseTest do
  use ExUnit.Case, async: true

  doctest Denox.Run.Base

  describe "resolve_specifier/1" do
    test "passes through npm: prefix" do
      assert Denox.Run.Base.resolve_specifier("npm:cowsay") == "npm:cowsay"
    end

    test "passes through jsr: prefix" do
      assert Denox.Run.Base.resolve_specifier("jsr:@std/path") == "jsr:@std/path"
    end

    test "passes through http:// prefix" do
      assert Denox.Run.Base.resolve_specifier("http://example.com/mod.ts") ==
               "http://example.com/mod.ts"
    end

    test "passes through https:// prefix" do
      assert Denox.Run.Base.resolve_specifier("https://deno.land/x/mod.ts") ==
               "https://deno.land/x/mod.ts"
    end

    test "passes through file:// prefix" do
      assert Denox.Run.Base.resolve_specifier("file:///tmp/script.ts") ==
               "file:///tmp/script.ts"
    end

    test "prefixes scoped package with npm:" do
      assert Denox.Run.Base.resolve_specifier("@scope/pkg") == "npm:@scope/pkg"
    end

    test "leaves bare file paths as-is" do
      assert Denox.Run.Base.resolve_specifier("server.ts") == "server.ts"
    end

    test "leaves absolute paths as-is" do
      assert Denox.Run.Base.resolve_specifier("/tmp/script.ts") == "/tmp/script.ts"
    end

    test "leaves bare module names as-is" do
      assert Denox.Run.Base.resolve_specifier("cowsay") == "cowsay"
    end
  end
end
