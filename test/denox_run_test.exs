defmodule DenoxRunTest do
  use ExUnit.Case, async: false

  # Run tests require deno CLI.
  @moduletag :deno
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

      # Send data to stdin to let process exit
      Denox.Run.send(pid, "quit")
      Process.sleep(500)

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

    test "no permissions", %{tmp_dir: dir} do
      script = write_script(dir, "ok2.ts", ~s[console.log("ok");])

      {:ok, pid} =
        Denox.Run.start_link(
          file: script,
          permissions: nil
        )

      {:ok, line} = Denox.Run.recv(pid, timeout: 5000)
      assert line == "ok"
    end
  end
end
