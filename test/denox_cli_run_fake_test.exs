defmodule DenoxCLIRunFakeTest do
  @moduledoc """
  Tests for Denox.CLI.Run using a fake shell script as the "deno" binary.

  This allows testing the Port management, arg building, and permission logic
  without requiring the real bundled CLI binary.
  """
  use ExUnit.Case, async: false

  @fake_version "fake-cli-test-88.88.88"
  @cli_dir "_build/denox_cli-#{@fake_version}"
  @cli_path "#{@cli_dir}/deno"

  setup do
    original = Application.get_env(:denox, :cli)

    File.mkdir_p!(@cli_dir)

    on_exit(fn ->
      File.rm_rf(@cli_dir)

      if original,
        do: Application.put_env(:denox, :cli, original),
        else: Application.delete_env(:denox, :cli)
    end)

    Application.put_env(:denox, :cli, version: @fake_version)

    :ok
  end

  defp write_fake_deno(script_body) do
    File.write!(@cli_path, "#!/bin/sh\n#{script_body}\n")
    File.chmod!(@cli_path, 0o755)
  end

  describe "init_backend — success path" do
    test "opens a port and captures output" do
      write_fake_deno(~s[echo "hello from fake deno"])

      {:ok, pid} = Denox.CLI.Run.start_link(file: "test.ts", permissions: :all)

      # Covers init_backend success, handle_info {:eol, line}, dispatch_line
      assert {:ok, "hello from fake deno"} = Denox.CLI.Run.recv(pid, timeout: 5000)
      Denox.CLI.Run.stop(pid)
    end

    test "alive? returns true while running, false after exit" do
      write_fake_deno(~s[echo "done"])

      {:ok, pid} = Denox.CLI.Run.start_link(file: "test.ts", permissions: :all)
      Denox.CLI.Run.subscribe(pid)

      # alive_backend? covers line 88
      assert Denox.CLI.Run.alive?(pid)

      assert_receive {:denox_run_exit, ^pid, _}, 5000

      # alive_backend? after port closes
      refute Denox.CLI.Run.alive?(pid)
    end

    test "os_pid returns an integer" do
      write_fake_deno(~s[echo "pid test"; sleep 60])

      {:ok, pid} = Denox.CLI.Run.start_link(file: "test.ts", permissions: :all)

      # Covers Port.info(port, :os_pid) → {:os_pid, pid}
      assert {:ok, os_pid} = Denox.CLI.Run.os_pid(pid)
      assert is_integer(os_pid)
      assert os_pid > 0

      Denox.CLI.Run.stop(pid)
    end
  end

  describe "send_backend" do
    test "sends data to the port stdin" do
      write_fake_deno("read line; echo \"got:$line\"")

      {:ok, pid} = Denox.CLI.Run.start_link(file: "test.ts", permissions: :all)

      # send_backend covers Port.command (line 74)
      :ok = Denox.CLI.Run.send(pid, "hello\n")
      assert {:ok, line} = Denox.CLI.Run.recv(pid, timeout: 5000)
      assert line =~ "got:"

      Denox.CLI.Run.stop(pid)
    end

    test "returns {:error, :closed} after process has exited" do
      write_fake_deno(~s[echo "bye"])

      {:ok, pid} = Denox.CLI.Run.start_link(file: "test.ts", permissions: :all)
      Denox.CLI.Run.subscribe(pid)
      assert_receive {:denox_run_exit, ^pid, _}, 5000

      # send_backend rescue ArgumentError (line 77)
      assert {:error, :closed} = Denox.CLI.Run.send(pid, "too late")
    end
  end

  describe "stop_backend" do
    test "closes the port" do
      write_fake_deno("sleep 60")

      {:ok, pid} = Denox.CLI.Run.start_link(file: "test.ts", permissions: :all)
      assert Denox.CLI.Run.alive?(pid)

      # stop_backend covers Port.close (line 82)
      Denox.CLI.Run.stop(pid)
      refute Process.alive?(pid)
    end
  end

  describe "permissions_to_args" do
    test "covers :none permissions" do
      write_fake_deno(~s[echo "ok"])

      # permissions: :none → permissions_to_args(:none) → [] (line 165)
      {:ok, pid} = Denox.CLI.Run.start_link(file: "test.ts", permissions: :none)
      {:ok, _} = Denox.CLI.Run.recv(pid, timeout: 5000)
      Denox.CLI.Run.stop(pid)
    end

    test "covers nil permissions" do
      write_fake_deno(~s[echo "ok"])

      # permissions: nil → permissions_to_args(nil) → [] (line 164)
      {:ok, pid} = Denox.CLI.Run.start_link(file: "test.ts", permissions: nil)
      {:ok, _} = Denox.CLI.Run.recv(pid, timeout: 5000)
      Denox.CLI.Run.stop(pid)
    end

    test "covers {key, true} permission flag" do
      write_fake_deno(~s[echo "ok"])

      # permissions: [allow_net: true] → permission_to_flag({:allow_net, true}) (line 171-172)
      {:ok, pid} =
        Denox.CLI.Run.start_link(file: "test.ts", permissions: [allow_net: true])

      {:ok, _} = Denox.CLI.Run.recv(pid, timeout: 5000)
      Denox.CLI.Run.stop(pid)
    end

    test "covers {key, list_of_values} permission flag" do
      write_fake_deno(~s[echo "ok"])

      # permissions: [allow_env: ["FOO"]] → permission_to_flag({:allow_env, ["FOO"]}) (line 175-176)
      {:ok, pid} =
        Denox.CLI.Run.start_link(file: "test.ts", permissions: [allow_env: ["FOO", "BAR"]])

      {:ok, _} = Denox.CLI.Run.recv(pid, timeout: 5000)
      Denox.CLI.Run.stop(pid)
    end

    test "covers {key, false} permission flag" do
      write_fake_deno(~s[echo "ok"])

      # permissions: [allow_net: false] → permission_to_flag({:allow_net, false}) → [] (line 179)
      {:ok, pid} =
        Denox.CLI.Run.start_link(file: "test.ts", permissions: [allow_net: false])

      {:ok, _} = Denox.CLI.Run.recv(pid, timeout: 5000)
      Denox.CLI.Run.stop(pid)
    end
  end

  describe "resolve_specifier" do
    test "covers @ prefix → npm: resolution" do
      write_fake_deno(~s[echo "ok"])

      # package: "@scope/pkg" → resolve_specifier → "npm:@scope/pkg" (line 147-148)
      {:ok, pid} = Denox.CLI.Run.start_link(package: "@scope/pkg", permissions: :all)
      {:ok, _} = Denox.CLI.Run.recv(pid, timeout: 5000)
      Denox.CLI.Run.stop(pid)
    end

    test "covers bare specifier passthrough" do
      write_fake_deno(~s[echo "ok"])

      # package: "bare-pkg" → resolve_specifier → "bare-pkg" (line 150-151)
      {:ok, pid} = Denox.CLI.Run.start_link(package: "bare-pkg", permissions: :all)
      {:ok, _} = Denox.CLI.Run.recv(pid, timeout: 5000)
      Denox.CLI.Run.stop(pid)
    end
  end

  describe "resolve_specifier — file:// prefix" do
    test "passes file:// specifier through unchanged" do
      write_fake_deno(~s[echo "ok"])

      # package: "file://something" → resolve_specifier → "file://something" (line 144-145)
      {:ok, pid} = Denox.CLI.Run.start_link(package: "file://test.ts", permissions: :all)
      {:ok, _} = Denox.CLI.Run.recv(pid, timeout: 5000)
      Denox.CLI.Run.stop(pid)
    end

    test "passes npm: specifier through unchanged" do
      write_fake_deno(~s[echo "ok"])

      # package: "npm:pkg@1.0" → resolve_specifier → unchanged (line 144-145)
      {:ok, pid} = Denox.CLI.Run.start_link(package: "npm:pkg@1.0", permissions: :all)
      {:ok, _} = Denox.CLI.Run.recv(pid, timeout: 5000)
      Denox.CLI.Run.stop(pid)
    end
  end

  describe "handle_info fallback" do
    test "unknown messages are silently ignored" do
      write_fake_deno("sleep 60")

      {:ok, pid} = Denox.CLI.Run.start_link(file: "test.ts", permissions: :all)

      # Sends an unknown message — handle_info/2 line 109 → super(msg, state) (line 110)
      send(pid, {:unknown_msg, :for_testing})

      # GenServer should still be alive
      assert Denox.CLI.Run.alive?(pid)
      Denox.CLI.Run.stop(pid)
    end
  end

  describe "build_env" do
    test "converts string env keys/values" do
      write_fake_deno(~s[echo "ok"])

      # env: %{"KEY" => "value"} → env_to_charlist binary (line 196)
      {:ok, pid} =
        Denox.CLI.Run.start_link(
          file: "test.ts",
          permissions: :all,
          env: %{"MY_TEST_KEY" => "my_value"}
        )

      {:ok, _} = Denox.CLI.Run.recv(pid, timeout: 5000)
      Denox.CLI.Run.stop(pid)
    end

    test "converts atom env keys/values" do
      write_fake_deno(~s[echo "ok"])

      # env: %{KEY: "value"} → env_to_charlist atom key (line 195)
      {:ok, pid} =
        Denox.CLI.Run.start_link(
          file: "test.ts",
          permissions: :all,
          env: %{MY_ATOM_KEY: "atom_value"}
        )

      {:ok, _} = Denox.CLI.Run.recv(pid, timeout: 5000)
      Denox.CLI.Run.stop(pid)
    end
  end

  describe "deno_flags and args" do
    test "passes deno_flags and script args" do
      write_fake_deno(~s[echo "ok"])

      # covers extra_flags and extra_args in build_args
      {:ok, pid} =
        Denox.CLI.Run.start_link(
          file: "test.ts",
          permissions: :all,
          deno_flags: ["--no-check"],
          args: ["--port", "3000"]
        )

      {:ok, _} = Denox.CLI.Run.recv(pid, timeout: 5000)
      Denox.CLI.Run.stop(pid)
    end
  end

  describe "error paths" do
    test "raises ArgumentError for unknown permission flag" do
      write_fake_deno(~s[echo "ok"])
      Process.flag(:trap_exit, true)

      # permission_to_flag({:unknown_perm, true}) → line 182: raise ArgumentError
      assert {:error, {%ArgumentError{message: msg}, _}} =
               Denox.CLI.Run.start_link(file: "test.ts", permissions: [unknown_perm: true])

      assert msg =~ "unknown permission flag"
    end

    test "raises ArgumentError for invalid env value type" do
      write_fake_deno(~s[echo "ok"])
      Process.flag(:trap_exit, true)

      # env_to_charlist(123) → line 199: raise ArgumentError
      assert {:error, {%ArgumentError{message: msg}, _}} =
               Denox.CLI.Run.start_link(
                 file: "test.ts",
                 permissions: :all,
                 env: %{"KEY" => 123}
               )

      assert msg =~ "env values must be atoms or binaries"
    end
  end

  describe "noeol chunk handling" do
    test "receives output without trailing newline as a dispatch_line call" do
      # printf outputs without newline → port sends {:noeol, chunk} → line 100
      write_fake_deno("printf 'no newline here'")

      {:ok, pid} = Denox.CLI.Run.start_link(file: "test.ts", permissions: :all)
      Denox.CLI.Run.subscribe(pid)

      assert_receive {:denox_run_stdout, ^pid, line}, 5000
      assert line =~ "no newline"

      Denox.CLI.Run.stop(pid)
    end
  end
end
