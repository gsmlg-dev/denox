defmodule Denox.Permissions do
  @moduledoc false
  # Shared permission key validation and JSON encoding for NIF backends.
  # Used by both `Denox` and `Denox.Run` to build the permissions JSON
  # sent to the Rust NIF layer.

  @valid_keys ~w(
    allow_read allow_write allow_net allow_env allow_run allow_ffi allow_sys
    deny_read deny_write deny_net deny_env deny_run deny_ffi deny_sys
  )a

  @doc false
  @spec to_nif_json(:all | :none | nil | keyword()) :: String.t()
  def to_nif_json(:all), do: Denox.JSON.encode!(%{mode: "allow_all"})
  def to_nif_json(:none), do: Denox.JSON.encode!(%{mode: "deny_all"})
  def to_nif_json(nil), do: ""

  def to_nif_json(perms) when is_list(perms) do
    granular =
      Enum.reduce(perms, %{mode: "granular"}, fn
        {key, true}, acc when key in @valid_keys ->
          Map.put(acc, Atom.to_string(key), true)

        {key, values}, acc when key in @valid_keys and is_list(values) ->
          Map.put(acc, Atom.to_string(key), values)

        {_key, false}, acc ->
          acc

        {key, _value}, _acc ->
          raise ArgumentError, "unknown permission key: #{inspect(key)}"
      end)

    Denox.JSON.encode!(granular)
  end
end
