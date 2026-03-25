defmodule Denox.PermissionsTest do
  use ExUnit.Case, async: true

  describe "to_nif_json/1" do
    test ":all produces allow_all mode" do
      json = Denox.Permissions.to_nif_json(:all)
      assert %{"mode" => "allow_all"} = Denox.JSON.decode!(json)
    end

    test ":none produces deny_all mode" do
      json = Denox.Permissions.to_nif_json(:none)
      assert %{"mode" => "deny_all"} = Denox.JSON.decode!(json)
    end

    test "nil produces empty string" do
      assert "" = Denox.Permissions.to_nif_json(nil)
    end

    test "granular with boolean flags" do
      json = Denox.Permissions.to_nif_json(allow_net: true, deny_env: true)
      decoded = Denox.JSON.decode!(json)
      assert decoded["mode"] == "granular"
      assert decoded["allow_net"] == true
      assert decoded["deny_env"] == true
    end

    test "granular with list values" do
      json = Denox.Permissions.to_nif_json(allow_read: ["/tmp", "/data"])
      decoded = Denox.JSON.decode!(json)
      assert decoded["mode"] == "granular"
      assert decoded["allow_read"] == ["/tmp", "/data"]
    end

    test "false values are filtered out" do
      json = Denox.Permissions.to_nif_json(allow_net: true, allow_env: false)
      decoded = Denox.JSON.decode!(json)
      assert decoded["mode"] == "granular"
      assert decoded["allow_net"] == true
      refute Map.has_key?(decoded, "allow_env")
    end

    test "raises on unknown permission key" do
      assert_raise ArgumentError, ~r/unknown permission key/, fn ->
        Denox.Permissions.to_nif_json(allow_banana: true)
      end
    end

    test "all valid keys are accepted" do
      valid_keys = ~w(
        allow_read allow_write allow_net allow_env allow_run allow_ffi allow_sys
        deny_read deny_write deny_net deny_env deny_run deny_ffi deny_sys
      )a

      perms = Enum.map(valid_keys, &{&1, true})
      json = Denox.Permissions.to_nif_json(perms)
      decoded = Denox.JSON.decode!(json)
      assert decoded["mode"] == "granular"

      for key <- valid_keys do
        assert decoded[Atom.to_string(key)] == true
      end
    end
  end
end
