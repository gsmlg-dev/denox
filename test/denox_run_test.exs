defmodule DenoxRunTest do
  use ExUnit.Case, async: false

  # Run tests use the NIF-backed runtime (no external deno CLI required).
  @moduletag :tmp_dir

  defp write_script(dir, name, code) do
    path = Path.join(dir, name)
    File.write!(path, code)
    path
  end

  describe "start_link/1" do
    test "runs a simple script and captures output", %{tmp_dir: dir} do
      script = write_script(dir, "hello.ts", ~s[console.log("hello from deno");])

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: :all
        )

      {:ok, line} = Denox.Run.recv(pid, timeout: 5000)
      assert line == "hello from deno"
    end

    test "requires package or file" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: msg}, _}} =
               Denox.Run.start_link([])

      assert msg =~ "either :package or :file"
    end

    test "runs with granular permissions", %{tmp_dir: dir} do
      script = write_script(dir, "env.ts", ~s[console.log(typeof Deno.env);])

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: [allow_env: true]
        )

      {:ok, line} = Denox.Run.recv(pid, timeout: 5000)
      assert line == "object"
    end

    test "passes environment variables", %{tmp_dir: dir} do
      script = write_script(dir, "getenv.ts", ~s[console.log(Deno.env.get("TEST_DENOX_VAR"));])

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: [allow_env: ["TEST_DENOX_VAR"]],
          env: %{"TEST_DENOX_VAR" => "hello_denox"}
        )

      {:ok, line} = Denox.Run.recv(pid, timeout: 5000)
      assert line == "hello_denox"
    end

    test "passes script arguments", %{tmp_dir: dir} do
      script = write_script(dir, "args.ts", ~s[console.log(Deno.args.join(","));])

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: :all,
          args: ["--foo", "bar"]
        )

      {:ok, line} = Denox.Run.recv(pid, timeout: 5000)
      assert line == "--foo,bar"
    end
  end

  describe "send/2" do
    test "sends data to stdin", %{tmp_dir: dir} do
      script =
        write_script(dir, "echo.ts", """
        const buf = new Uint8Array(1024);
        const n = await Deno.stdin.read(buf);
        const line = new TextDecoder().decode(buf.subarray(0, n!)).trim();
        console.log("echo:" + line);
        """)

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: :all
        )

      :ok = Denox.Run.send(pid, "test_input")
      {:ok, line} = Denox.Run.recv(pid, timeout: 5000)
      assert line == "echo:test_input"
    end
  end

  describe "subscribe/1" do
    test "receives stdout messages", %{tmp_dir: dir} do
      script =
        write_script(dir, "multi.ts", """
        console.log("line1");
        console.log("line2");
        """)

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: :all
        )

      Denox.Run.subscribe(pid)

      assert_receive {:denox_run_stdout, ^pid, "line1"}, 5000
      assert_receive {:denox_run_stdout, ^pid, "line2"}, 5000
    end

    test "receives exit message", %{tmp_dir: dir} do
      script = write_script(dir, "done.ts", ~s[console.log("done");])

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: :all
        )

      Denox.Run.subscribe(pid)

      assert_receive {:denox_run_exit, ^pid, 0}, 5000
    end
  end

  describe "alive?/1" do
    test "returns true while running, false after exit", %{tmp_dir: dir} do
      script =
        write_script(dir, "wait.ts", """
        const buf = new Uint8Array(1024);
        await Deno.stdin.read(buf);
        """)

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: :all
        )

      assert Denox.Run.alive?(pid)

      Denox.Run.subscribe(pid)
      # Send data to stdin to let process exit naturally
      Denox.Run.send(pid, "quit")
      # Wait for exit notification instead of sleeping
      assert_receive {:denox_run_exit, ^pid, _status}, 5000

      refute Denox.Run.alive?(pid)
    end
  end

  describe "stop/1" do
    test "terminates the subprocess", %{tmp_dir: dir} do
      script = write_script(dir, "forever.ts", "await new Promise(() => {});")

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: :all
        )

      assert Denox.Run.alive?(pid)
      Denox.Run.stop(pid)
      refute Process.alive?(pid)
    end
  end

  describe "recv/2" do
    test "returns {:error, :timeout} when no output within timeout", %{tmp_dir: dir} do
      script =
        write_script(dir, "silent.ts", """
        const buf = new Uint8Array(1024);
        await Deno.stdin.read(buf);
        """)

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: :all
        )

      assert {:error, :timeout} = Denox.Run.recv(pid, timeout: 200)
      Denox.Run.stop(pid)
    end

    test "returns {:error, :closed} after process exits", %{tmp_dir: dir} do
      script = write_script(dir, "quick.ts", ~s[console.log("bye");])

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: :all
        )

      Denox.Run.subscribe(pid)

      # Drain the output line
      {:ok, "bye"} = Denox.Run.recv(pid, timeout: 5000)

      # Wait for exit notification before checking closed state
      assert_receive {:denox_run_exit, ^pid, _status}, 5000

      assert {:error, :closed} = Denox.Run.recv(pid, timeout: 1000)
    end

    test "pending recv gets {:error, :closed} when process exits while waiting", %{tmp_dir: dir} do
      # A process exits while a recv is pending — drain_waiters replies :closed.
      script = write_script(dir, "exit_while_recv.ts", "// empty script, exits immediately")

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: :all
        )

      # Start recv in a task — will block until output or exit
      task = Task.async(fn -> Denox.Run.recv(pid, timeout: 5000) end)

      # The script exits immediately, so drain_waiters replies :closed
      assert {:error, :closed} = Task.await(task, 5000)
    end

    test "timeout does not consume a line from a subsequent recv", %{tmp_dir: dir} do
      # A recv that times out should NOT steal the next arriving line.
      # Regression test for stale recv_waiters after GenServer.call timeout.
      script =
        write_script(dir, "delayed.ts", """
        const buf = new Uint8Array(1024);
        await Deno.stdin.read(buf);
        console.log("delayed_line");
        """)

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: :all
        )

      # This recv times out — no output yet
      assert {:error, :timeout} = Denox.Run.recv(pid, timeout: 100)

      # Trigger output
      Denox.Run.send(pid, "go")

      # The next recv should get the line, not the timed-out waiter
      assert {:ok, "delayed_line"} = Denox.Run.recv(pid, timeout: 5000)
    end

    test "buffers lines and returns them in order", %{tmp_dir: dir} do
      script =
        write_script(dir, "lines.ts", """
        for (let i = 1; i <= 5; i++) {
          console.log("line" + i);
        }
        """)

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: :all
        )

      assert {:ok, "line1"} = Denox.Run.recv(pid, timeout: 5000)
      assert {:ok, "line2"} = Denox.Run.recv(pid, timeout: 5000)
      assert {:ok, "line3"} = Denox.Run.recv(pid, timeout: 5000)
      assert {:ok, "line4"} = Denox.Run.recv(pid, timeout: 5000)
      assert {:ok, "line5"} = Denox.Run.recv(pid, timeout: 5000)
    end

    test "recv returns immediately when line is already buffered", %{tmp_dir: dir} do
      # Subscribe first so the line buffers (no recv waiter) instead of being served to a waiter.
      # When subscribe receives the message, we know the line is in stdout_buffer.
      script = write_script(dir, "pre_buffered.ts", ~s[console.log("buffered_line");])

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: :all
        )

      Denox.Run.subscribe(pid)
      # Wait until the line arrives and is buffered
      assert_receive {:denox_run_stdout, ^pid, "buffered_line"}, 5000

      # recv should find the line in the buffer immediately (no blocking)
      assert {:ok, "buffered_line"} = Denox.Run.recv(pid)
    end

    test "stale recv_timeout message is silently ignored", %{tmp_dir: dir} do
      # Send a {:recv_timeout, ref} message with a ref that matches no current waiter.
      # This simulates the race where a line arrived and served the waiter before the timer fired.
      script = write_script(dir, "stale_timeout.ts", "await new Promise(() => {})")

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: :all
        )

      # Send a stale timeout ref directly to the GenServer
      send(pid, {:recv_timeout, make_ref()})

      # GenServer should still be alive and responsive
      assert Denox.Run.alive?(pid)
      Denox.Run.stop(pid)
    end
  end

  describe "send/2 edge cases" do
    test "returns {:error, :closed} after process has exited", %{tmp_dir: dir} do
      script = write_script(dir, "exit_fast.ts", ~s[console.log("done");])

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: :all
        )

      # Wait for process to exit
      Denox.Run.subscribe(pid)
      assert_receive {:denox_run_exit, ^pid, 0}, 5000

      assert {:error, :closed} = Denox.Run.send(pid, "too late")
    end
  end

  describe "unsubscribe/1" do
    test "stops receiving messages after unsubscribe", %{tmp_dir: dir} do
      script =
        write_script(dir, "unsub.ts", """
        const buf = new Uint8Array(1024);
        await Deno.stdin.read(buf);
        console.log("after_unsub");
        """)

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: :all
        )

      Denox.Run.subscribe(pid)
      Denox.Run.unsubscribe(pid)

      Denox.Run.send(pid, "go")
      refute_receive {:denox_run_stdout, ^pid, _}, 1000
    end
  end

  describe "telemetry" do
    test "emits :recv event for each stdout line", %{tmp_dir: dir} do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-run-recv-#{inspect(ref)}",
        [:denox, :run, :recv],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:telemetry_recv, measurements, metadata})
        end,
        nil
      )

      script = write_script(dir, "telem_recv.ts", ~s[console.log("hello");])

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: :all
        )

      {:ok, "hello"} = Denox.Run.recv(pid, timeout: 5000)

      assert_receive {:telemetry_recv, %{system_time: _}, %{line_bytes: bytes, backend: :nif}},
                     1000

      assert bytes == byte_size("hello")

      :telemetry.detach("test-run-recv-#{inspect(ref)}")
    end

    test "emits :start and :stop events", %{tmp_dir: dir} do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-run-start-#{inspect(ref)}",
        [:denox, :run, :start],
        fn _event, _measurements, metadata, _ ->
          send(test_pid, {:telemetry_start, metadata})
        end,
        nil
      )

      :telemetry.attach(
        "test-run-stop-#{inspect(ref)}",
        [:denox, :run, :stop],
        fn _event, _measurements, metadata, _ ->
          send(test_pid, {:telemetry_stop, metadata})
        end,
        nil
      )

      script = write_script(dir, "telem.ts", ~s[console.log("ok");])

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: :all
        )

      assert_receive {:telemetry_start, %{backend: :nif}}, 5000

      Denox.Run.subscribe(pid)
      assert_receive {:denox_run_exit, ^pid, 0}, 5000
      assert_receive {:telemetry_stop, %{backend: :nif, exit_status: 0}}, 5000

      :telemetry.detach("test-run-start-#{inspect(ref)}")
      :telemetry.detach("test-run-stop-#{inspect(ref)}")
    end
  end

  describe "permissions" do
    test "all permissions", %{tmp_dir: dir} do
      script = write_script(dir, "ok.ts", ~s[console.log("ok");])

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: :all
        )

      {:ok, line} = Denox.Run.recv(pid, timeout: 5000)
      assert line == "ok"
    end

    test "no permissions (nil)", %{tmp_dir: dir} do
      script = write_script(dir, "ok2.ts", ~s[console.log("ok");])

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: nil
        )

      {:ok, line} = Denox.Run.recv(pid, timeout: 5000)
      assert line == "ok"
    end

    test "permissions :none", %{tmp_dir: dir} do
      script = write_script(dir, "ok_none.ts", ~s[console.log("ok");])

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: :none
        )

      {:ok, line} = Denox.Run.recv(pid, timeout: 5000)
      assert line == "ok"
    end

    test "false permissions entries are silently dropped (treated as unset)", %{tmp_dir: dir} do
      # {key, false} in permissions list should be ignored, not passed to deno
      # This is equivalent to allow_env: true alone
      script = write_script(dir, "perm_false.ts", ~s[console.log(typeof Deno.env);])

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: [allow_env: true, allow_net: false]
        )

      {:ok, line} = Denox.Run.recv(pid, timeout: 5000)
      assert line == "object"
    end

    test "granular allow_env with list", %{tmp_dir: dir} do
      script =
        write_script(
          dir,
          "perm_list.ts",
          ~s[console.log(Deno.env.get("TEST_ALLOW_VAR") ?? "undefined");]
        )

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: [allow_env: ["TEST_ALLOW_VAR"]],
          env: %{"TEST_ALLOW_VAR" => "allowed"}
        )

      {:ok, line} = Denox.Run.recv(pid, timeout: 5000)
      assert line == "allowed"
    end
  end

  describe "os_pid/1" do
    test "returns :not_available for NIF-backed runtime", %{tmp_dir: dir} do
      script = write_script(dir, "long.ts", "await new Promise(r => setTimeout(r, 30000));")
      {:ok, pid} = Denox.Run.start_link(file: script, permissions: :all)
      assert {:error, :not_available} = Denox.Run.os_pid(pid)
      Denox.Run.stop(pid)
    end

    test "returns :not_running after runtime exits", %{tmp_dir: dir} do
      script = write_script(dir, "quick.ts", ~s[console.log("done");])
      {:ok, pid} = Denox.Run.start_link(file: script, permissions: :all)
      Denox.Run.subscribe(pid)
      assert_receive {:denox_run_exit, ^pid, _}, 5000
      assert {:error, :not_running} = Denox.Run.os_pid(pid)
    end
  end

  describe "subscriber :DOWN cleanup" do
    test "removes subscriber when subscriber process dies", %{tmp_dir: dir} do
      script = write_script(dir, "long_sub.ts", "await new Promise(r => setTimeout(r, 30000));")
      {:ok, run_pid} = Denox.Run.start_link(file: script, permissions: :all)

      subscriber =
        spawn(fn ->
          Denox.Run.subscribe(run_pid)

          receive do
            :never -> :ok
          end
        end)

      Process.sleep(50)
      Process.exit(subscriber, :kill)
      Process.sleep(50)

      assert Denox.Run.alive?(run_pid)
      Denox.Run.stop(run_pid)
    end

    test "cleans up recv waiter when calling process dies", %{tmp_dir: dir} do
      script =
        write_script(dir, "long_recv.ts", "await new Promise(r => setTimeout(r, 30000));")

      {:ok, run_pid} = Denox.Run.start_link(file: script, permissions: :all)

      waiter = spawn(fn -> Denox.Run.recv(run_pid, timeout: 30_000) end)
      Process.sleep(50)
      Process.exit(waiter, :kill)
      Process.sleep(50)

      assert Denox.Run.alive?(run_pid)
      Denox.Run.stop(run_pid)
    end
  end

  describe "unknown call" do
    test "returns error for unrecognized GenServer call", %{tmp_dir: dir} do
      script = write_script(dir, "long2.ts", "await new Promise(r => setTimeout(r, 30000));")
      {:ok, pid} = Denox.Run.start_link(file: script, permissions: :all)
      assert {:error, {:unknown_call, :bogus_message}} = GenServer.call(pid, :bogus_message)
      Denox.Run.stop(pid)
    end
  end

  describe "start_link/1 error paths" do
    test "runtime exits on nonexistent file load failure", %{tmp_dir: _dir} do
      # A nonexistent file — NIF starts the runtime but module load fails.
      # The runtime sends an error to stdout and sets alive=false.
      {:ok, pid} =
        Denox.Run.start_link(
          file: "/nonexistent/path/to/script.ts",
          permissions: :all
        )

      Denox.Run.subscribe(pid)

      # Runtime should exit quickly after failing to load the module
      assert_receive {:denox_run_exit, ^pid, _status}, 5000
    end

    test "file:// prefix is passed as-is to the runtime" do
      # file:// prefix specifier (resolve_specifier passthrough)
      {:ok, pid} =
        Denox.Run.start_link(
          file: "file:///nonexistent/script.ts",
          permissions: :all
        )

      Denox.Run.subscribe(pid)
      assert_receive {:denox_run_exit, ^pid, _status}, 5000
    end
  end

  describe "recv waiter cleanup on caller death" do
    test "DOWN for a recv waiter cancels the timer and cleans up state", %{tmp_dir: dir} do
      # A script that blocks on stdin forever — no output will arrive.
      script =
        write_script(dir, "block_stdin.ts", """
        const buf = new Uint8Array(1024);
        await Deno.stdin.read(buf);
        """)

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: :all
        )

      # Spawn a process that calls recv/2, then immediately kill it.
      # This exercises the DOWN handler path for recv_waiters in Denox.Run.Base:
      # wref == ref → Process.cancel_timer(timer_ref) is called.
      waiter_pid =
        spawn(fn ->
          Denox.Run.recv(pid, timeout: 10_000)
        end)

      # Give the waiter time to register in recv_waiters
      Process.sleep(100)

      # Kill the waiter before the line arrives
      Process.exit(waiter_pid, :kill)

      # Give the GenServer time to process the DOWN message
      Process.sleep(100)

      # The GenServer should still be alive and healthy
      assert Process.alive?(pid)
      assert Denox.Run.alive?(pid)

      Denox.Run.stop(pid)
    end
  end
end
