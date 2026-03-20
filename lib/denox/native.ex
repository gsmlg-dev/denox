defmodule Denox.Native do
  @moduledoc false
  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :denox,
    crate: "denox_nif",
    base_url: "https://github.com/gsmlg-dev/denox/releases/download/v#{version}",
    version: version,
    targets: [
      "aarch64-apple-darwin",
      "x86_64-apple-darwin",
      "x86_64-unknown-linux-gnu",
      "aarch64-unknown-linux-gnu"
    ],
    nif_versions: ["2.16", "2.17"],
    force_build:
      System.get_env("DENOX_BUILD") in ["1", "true"] or
        Application.compile_env(:denox, :force_build, false)

  @spec create_snapshot(String.t(), boolean()) :: {:ok, binary()} | {:error, String.t()}
  def create_snapshot(_setup_code, _transpile), do: :erlang.nif_error(:nif_not_loaded)

  @spec runtime_new(
          String.t(),
          boolean(),
          String.t(),
          String.t(),
          pid() | nil,
          binary(),
          String.t()
        ) ::
          {:ok, reference()} | {:error, String.t()}
  def runtime_new(
        _base_dir,
        _sandbox,
        _cache_dir,
        _import_map_json,
        _callback_pid,
        _snapshot,
        _permissions_json
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  @spec eval(reference(), String.t(), boolean()) :: {:ok, String.t()} | {:error, String.t()}
  def eval(_resource, _code, _transpile), do: :erlang.nif_error(:nif_not_loaded)

  @spec eval_async(reference(), String.t(), boolean()) :: {:ok, String.t()} | {:error, String.t()}
  def eval_async(_resource, _code, _transpile), do: :erlang.nif_error(:nif_not_loaded)

  @spec eval_module(reference(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def eval_module(_resource, _path), do: :erlang.nif_error(:nif_not_loaded)

  @spec call_function(reference(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def call_function(_resource, _name, _args_json), do: :erlang.nif_error(:nif_not_loaded)

  @spec callback_reply(reference(), non_neg_integer(), String.t()) :: :ok | {:error, String.t()}
  def callback_reply(_resource, _callback_id, _result_json),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec callback_error(reference(), non_neg_integer(), String.t()) :: :ok | {:error, String.t()}
  def callback_error(_resource, _callback_id, _error_msg), do: :erlang.nif_error(:nif_not_loaded)

  # Part 2: Runtime Run NIFs

  @spec runtime_run(String.t(), String.t(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, reference()} | {:error, String.t()}
  def runtime_run(_specifier, _permissions_json, _env_vars_json, _args_json, _buffer_size),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec runtime_run_send(reference(), String.t()) :: {:ok, {}} | {:error, String.t()}
  def runtime_run_send(_resource, _data), do: :erlang.nif_error(:nif_not_loaded)

  @spec runtime_run_recv(reference()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def runtime_run_recv(_resource), do: :erlang.nif_error(:nif_not_loaded)

  @spec runtime_run_stop(reference()) :: :ok | {:error, String.t()}
  def runtime_run_stop(_resource), do: :erlang.nif_error(:nif_not_loaded)

  @spec runtime_run_alive(reference()) :: boolean()
  def runtime_run_alive(_resource), do: :erlang.nif_error(:nif_not_loaded)
end
