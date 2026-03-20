defmodule DenoxJsonTest do
  use ExUnit.Case, async: true

  alias Denox.JSON

  describe "module/0" do
    test "returns the configured JSON module" do
      assert JSON.module() == Elixir.JSON
    end
  end

  describe "encode!/1" do
    test "encodes a map" do
      assert JSON.encode!(%{"a" => 1}) == ~s({"a":1})
    end

    test "encodes a list" do
      assert JSON.encode!([1, 2, 3]) == "[1,2,3]"
    end

    test "encodes primitives" do
      assert JSON.encode!(42) == "42"
      assert JSON.encode!(true) == "true"
      assert JSON.encode!(nil) == "null"
    end
  end

  describe "decode/1" do
    test "decodes a JSON object" do
      assert JSON.decode(~s({"a":1})) == {:ok, %{"a" => 1}}
    end

    test "returns error on invalid JSON" do
      assert {:error, _} = JSON.decode("not json")
    end
  end

  describe "decode!/1" do
    test "decodes valid JSON" do
      assert JSON.decode!("[1,2]") == [1, 2]
    end

    test "raises on invalid JSON" do
      assert_raise Elixir.JSON.DecodeError, fn -> JSON.decode!("bad") end
    end
  end

  describe "encode_pretty!/1" do
    test "pretty-prints a flat map" do
      result = JSON.encode_pretty!(%{"b" => 2, "a" => 1})
      assert result =~ "\"a\": 1"
      assert result =~ "\"b\": 2"
      assert result =~ "\n"
    end

    test "pretty-prints a list" do
      result = JSON.encode_pretty!([1, 2])
      assert result =~ "1"
      assert result =~ "2"
      assert result =~ "\n"
    end

    test "pretty-prints nested structures" do
      result = JSON.encode_pretty!(%{"items" => [1, 2], "meta" => %{"count" => 2}})
      assert result =~ "\"items\""
      assert result =~ "\"meta\""
      assert result =~ "\n"
    end

    test "pretty-prints an empty map" do
      assert JSON.encode_pretty!(%{}) == "{}"
    end

    test "pretty-prints an empty list" do
      assert JSON.encode_pretty!([]) == "[]"
    end

    test "pretty-prints scalar values" do
      assert JSON.encode_pretty!(42) == "42"
      assert JSON.encode_pretty!(true) == "true"
      assert JSON.encode_pretty!(nil) == "null"
    end
  end
end
