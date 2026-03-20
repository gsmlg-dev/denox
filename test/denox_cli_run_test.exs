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

  setup do
    original = Application.get_env(:denox, :cli)

    on_exit(fn ->
      if original do
        Application.put_env(:denox, :cli, original)
      else
        Application.delete_env(:denox, :cli)
      end
    end)

    :ok
  end

  describe "start_link/1" do
    test "runs a simple script and captures output", %{tmp_dir: dir} do
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
      Application.delete_env(:denox, :cli)
      Process.flag(:trap_exit, true)

      assert {:error, msg} = CLI.Run.start_link(file: "test.ts")
      assert msg =~ "Deno CLI not configured"
    end
  end

  describe "send/2" do
    test "sends data to stdin", %{tmp_dir: dir} do
      if ensure_cli_configured() == :skip do
        :ok
      else
        script =
          write_script(dir, "echo.ts", """
          const buf = new Uint8Array(1024);
          const n = await Deno.stdin.read(buf);
          const line = new TextDecoder().decode(buf.subarray(0, n!)).trim();
          console.log("echo:" + line);
          """)

        {:ok, pid} =
          CLI.Run.start_link(
            file: script,
            permissions: :all
          )

        :ok = CLI.Run.send(pid, "test_input")
        {:ok, line} = CLI.Run.recv(pid, timeout: 5000)
        assert line == "echo:test_input"
      end
    end
  end

  describe "subscribe/1" do
    test "receives stdout messages", %{tmp_dir: dir} do
      if ensure_cli_configured() == :skip do
        :ok
      else
        script =
          write_script(dir, "multi.ts", """
          console.log("line1");
          console.log("line2");
          """)

        {:ok, pid} =
          CLI.Run.start_link(
            file: script,
            permissions: :all
          )

        CLI.Run.subscribe(pid)

        assert_receive {:denox_run_stdout, ^pid, "line1"}, 5000
        assert_receive {:denox_run_stdout, ^pid, "line2"}, 5000
      end
    end

    test "receives exit message", %{tmp_dir: dir} do
      if ensure_cli_configured() == :skip do
        :ok
      else
        script = write_script(dir, "done.ts", ~s[console.log("done");])

        {:ok, pid} =
          CLI.Run.start_link(
            file: script,
            permissions: :all
          )

        CLI.Run.subscribe(pid)

        assert_receive {:denox_run_exit, ^pid, 0}, 5000
      end
    end
  end

  describe "alive?/1" do
    test "returns true while running, false after exit", %{tmp_dir: dir} do
      if ensure_cli_configured() == :skip do
        :ok
      else
        script =
          write_script(dir, "wait.ts", """
          const buf = new Uint8Array(1024);
          await Deno.stdin.read(buf);
          """)

        {:ok, pid} =
          CLI.Run.start_link(
            file: script,
            permissions: :all
          )

        assert CLI.Run.alive?(pid)

        CLI.Run.subscribe(pid)
        CLI.Run.send(pid, "quit")
        assert_receive {:denox_run_exit, ^pid, _status}, 5000

        refute CLI.Run.alive?(pid)
      end
    end
  end

  describe "stop/1" do
    test "terminates the subprocess", %{tmp_dir: dir} do
      if ensure_cli_configured() == :skip do
        :ok
      else
        script = write_script(dir, "forever.ts", "await new Promise(() => {});")

        {:ok, pid} =
          CLI.Run.start_link(
            file: script,
            permissions: :all
          )

        assert CLI.Run.alive?(pid)
        CLI.Run.stop(pid)
        refute Process.alive?(pid)
      end
    end
  end

  describe "os_pid/1" do
    test "returns the OS PID of the subprocess", %{tmp_dir: dir} do
      if ensure_cli_configured() == :skip do
        :ok
      else
        script =
          write_script(dir, "os_pid.ts", """
          const buf = new Uint8Array(1024);
          await Deno.stdin.read(buf);
          """)

        {:ok, pid} =
          CLI.Run.start_link(
            file: script,
            permissions: :all
          )

        assert {:ok, os_pid} = CLI.Run.os_pid(pid)
        assert is_integer(os_pid)
        assert os_pid > 0

        CLI.Run.stop(pid)
      end
    end
  end

  describe "recv/2 edge cases" do
    test "returns {:error, :timeout} when no output within timeout", %{tmp_dir: dir} do
      if ensure_cli_configured() == :skip do
        :ok
      else
        script =
          write_script(dir, "silent.ts", """
          const buf = new Uint8Array(1024);
          await Deno.stdin.read(buf);
          """)

        {:ok, pid} =
          CLI.Run.start_link(
            file: script,
            permissions: :all
          )

        assert {:error, :timeout} = CLI.Run.recv(pid, timeout: 200)
        CLI.Run.stop(pid)
      end
    end

    test "returns {:error, :closed} after process exits", %{tmp_dir: dir} do
      if ensure_cli_configured() == :skip do
        :ok
      else
        script = write_script(dir, "quick.ts", ~s[console.log("bye");])

        {:ok, pid} =
          CLI.Run.start_link(
            file: script,
            permissions: :all
          )

        CLI.Run.subscribe(pid)

        {:ok, "bye"} = CLI.Run.recv(pid, timeout: 5000)
        assert_receive {:denox_run_exit, ^pid, _status}, 5000

        assert {:error, :closed} = CLI.Run.recv(pid, timeout: 1000)
      end
    end

    test "buffers lines and returns them in order", %{tmp_dir: dir} do
      if ensure_cli_configured() == :skip do
        :ok
      else
        script =
          write_script(dir, "lines.ts", """
          for (let i = 1; i <= 5; i++) {
            console.log("line" + i);
          }
          """)

        {:ok, pid} =
          CLI.Run.start_link(
            file: script,
            permissions: :all
          )

        assert {:ok, "line1"} = CLI.Run.recv(pid, timeout: 5000)
        assert {:ok, "line2"} = CLI.Run.recv(pid, timeout: 5000)
        assert {:ok, "line3"} = CLI.Run.recv(pid, timeout: 5000)
        assert {:ok, "line4"} = CLI.Run.recv(pid, timeout: 5000)
        assert {:ok, "line5"} = CLI.Run.recv(pid, timeout: 5000)
      end
    end
  end

  describe "unsubscribe/1" do
    test "stops receiving messages after unsubscribe", %{tmp_dir: dir} do
      if ensure_cli_configured() == :skip do
        :ok
      else
        script =
          write_script(dir, "unsub.ts", """
          const buf = new Uint8Array(1024);
          await Deno.stdin.read(buf);
          console.log("after_unsub");
          """)

        {:ok, pid} =
          CLI.Run.start_link(
            file: script,
            permissions: :all
          )

        CLI.Run.subscribe(pid)
        CLI.Run.unsubscribe(pid)

        CLI.Run.send(pid, "go")
        refute_receive {:denox_run_stdout, ^pid, _}, 1000
      end
    end
  end

  describe "telemetry" do
    test "emits events with backend: :cli", %{tmp_dir: dir} do
      if ensure_cli_configured() == :skip do
        :ok
      else
        ref = make_ref()
        test_pid = self()

        :telemetry.attach(
          "test-cli-recv-#{inspect(ref)}",
          [:denox, :run, :recv],
          fn _event, measurements, metadata, _ ->
            send(test_pid, {:telemetry_recv, measurements, metadata})
          end,
          nil
        )

        :telemetry.attach(
          "test-cli-start-#{inspect(ref)}",
          [:denox, :run, :start],
          fn _event, _measurements, metadata, _ ->
            send(test_pid, {:telemetry_start, metadata})
          end,
          nil
        )

        script = write_script(dir, "telem.ts", ~s[console.log("hello");])

        {:ok, pid} =
          CLI.Run.start_link(
            file: script,
            permissions: :all
          )

        assert_receive {:telemetry_start, %{backend: :cli}}, 5000

        {:ok, "hello"} = CLI.Run.recv(pid, timeout: 5000)

        assert_receive {:telemetry_recv, %{system_time: _}, %{line_bytes: bytes, backend: :cli}},
                       1000

        assert bytes == byte_size("hello")

        :telemetry.detach("test-cli-recv-#{inspect(ref)}")
        :telemetry.detach("test-cli-start-#{inspect(ref)}")
      end
    end
  end

  describe "send/2 edge cases" do
    test "returns {:error, :closed} after process has exited", %{tmp_dir: dir} do
      if ensure_cli_configured() == :skip do
        :ok
      else
        script = write_script(dir, "exit_fast.ts", ~s[console.log("done");])

        {:ok, pid} =
          CLI.Run.start_link(
            file: script,
            permissions: :all
          )

        CLI.Run.subscribe(pid)
        assert_receive {:denox_run_exit, ^pid, 0}, 5000

        assert {:error, :closed} = CLI.Run.send(pid, "too late")
      end
    end
  end

  describe "permissions" do
    test "all permissions passes -A flag", %{tmp_dir: dir} do
      if ensure_cli_configured() == :skip do
        :ok
      else
        script = write_script(dir, "perm_all.ts", ~s[console.log("ok");])

        {:ok, pid} =
          CLI.Run.start_link(
            file: script,
            permissions: :all
          )

        {:ok, line} = CLI.Run.recv(pid, timeout: 5000)
        assert line == "ok"
      end
    end

    test "granular permissions with list values", %{tmp_dir: dir} do
      if ensure_cli_configured() == :skip do
        :ok
      else
        script =
          write_script(
            dir,
            "perm_list.ts",
            ~s[console.log(Deno.env.get("CLI_TEST_VAR") ?? "undefined");]
          )

        {:ok, pid} =
          CLI.Run.start_link(
            file: script,
            permissions: [allow_env: ["CLI_TEST_VAR"]],
            env: %{"CLI_TEST_VAR" => "works"}
          )

        {:ok, line} = CLI.Run.recv(pid, timeout: 5000)
        assert line == "works"
      end
    end
  end

  describe "environment variables" do
    test "passes env vars to the subprocess", %{tmp_dir: dir} do
      if ensure_cli_configured() == :skip do
        :ok
      else
        script =
          write_script(dir, "env.ts", ~s[console.log(Deno.env.get("MY_CLI_VAR"));])

        {:ok, pid} =
          CLI.Run.start_link(
            file: script,
            permissions: :all,
            env: %{"MY_CLI_VAR" => "hello_env"}
          )

        {:ok, line} = CLI.Run.recv(pid, timeout: 5000)
        assert line == "hello_env"
      end
    end
  end
end
