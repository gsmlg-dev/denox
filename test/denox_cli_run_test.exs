defmodule DenoxCLIRunTest do
  use ExUnit.Case, async: false

  alias Denox.CLI

  # CLI Run tests require deno CLI to be configured and installed.
  @moduletag :deno_cli
  @moduletag :tmp_dir

  defp write_script(dir, name, code) do
    path = Path.join(dir, name)
    File.write!(path, code)
    path
  end

  defp ensure_cli_configured do
    case CLI.configured_version() do
      nil -> :skip
      _version -> :ok
    end
  end

  describe "start_link/1" do
    test "runs a simple script and captures output", %{tmp_dir: dir} do
      # Skip when Denox.CLI is not configured in config (set :cli, version: "x.y.z")
      if ensure_cli_configured() == :skip do
        :ok
      else
        script = write_script(dir, "hello.ts", ~s[console.log("hello from cli");])

        {:ok, pid} =
          CLI.Run.start_link(
            file: script,
            permissions: :all
          )

        {:ok, line} = CLI.Run.recv(pid, timeout: 5000)
        assert line == "hello from cli"
      end
    end

    test "requires package or file" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: msg}, _}} =
               CLI.Run.start_link([])

      assert msg =~ "either :package or :file"
    end

    test "returns error when CLI not configured" do
      Process.flag(:trap_exit, true)
      original = Application.get_env(:denox, :cli)
      Application.delete_env(:denox, :cli)

      result = CLI.Run.start_link(file: "test.ts")
      assert {:error, msg} = result
      assert msg =~ "Deno CLI not configured"

      if original do
        Application.put_env(:denox, :cli, original)
      else
        Application.delete_env(:denox, :cli)
      end
    end
  end
end
