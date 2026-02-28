defmodule Denox.Native do
  use Rustler,
    otp_app: :denox,
    crate: "denox_nif"

  def runtime_new(), do: :erlang.nif_error(:nif_not_loaded)
  def eval(_resource, _code), do: :erlang.nif_error(:nif_not_loaded)
  def call_function(_resource, _name, _args_json), do: :erlang.nif_error(:nif_not_loaded)
end
