defmodule Denox.Native do
  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :denox,
    crate: "denox_nif",
    base_url: "https://github.com/gsmlg-dev/denox/releases/download/v#{version}",
    version: version,
    force_build:
      System.get_env("DENOX_BUILD") in ["1", "true"] or
        Application.compile_env(:denox, :force_build, false)

  def create_snapshot(_setup_code, _transpile), do: :erlang.nif_error(:nif_not_loaded)

  def runtime_new(_base_dir, _sandbox, _cache_dir, _import_map_json, _callback_pid, _snapshot),
    do: :erlang.nif_error(:nif_not_loaded)

  def eval(_resource, _code, _transpile), do: :erlang.nif_error(:nif_not_loaded)
  def eval_async(_resource, _code, _transpile), do: :erlang.nif_error(:nif_not_loaded)
  def eval_module(_resource, _path), do: :erlang.nif_error(:nif_not_loaded)
  def call_function(_resource, _name, _args_json), do: :erlang.nif_error(:nif_not_loaded)
  def callback_reply(_resource, _callback_id, _result_json), do: :erlang.nif_error(:nif_not_loaded)
  def callback_error(_resource, _callback_id, _error_msg), do: :erlang.nif_error(:nif_not_loaded)
end
