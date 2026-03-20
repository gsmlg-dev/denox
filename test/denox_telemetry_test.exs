defmodule DenoxTelemetryTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, rt} = Denox.runtime()
    %{rt: rt}
  end

  describe "telemetry events" do
    test "emits start and stop events on eval", %{rt: rt} do
      pid = self()

      start_id = "test-start-#{System.unique_integer([:positive])}"
      stop_id = "test-stop-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        start_id,
        [:denox, :eval, :start],
        fn _event, measurements, metadata, _config ->
          send(pid, {:start, measurements, metadata})
        end,
        nil
      )

      :telemetry.attach(
        stop_id,
        [:denox, :eval, :stop],
        fn _event, measurements, metadata, _config ->
          send(pid, {:stop, measurements, metadata})
        end,
        nil
      )

      {:ok, "3"} = Denox.eval(rt, "1 + 2")

      assert_receive {:start, %{system_time: _}, %{type: :eval}}
      assert_receive {:stop, %{duration: duration}, %{type: :eval}}
      assert is_integer(duration)
      assert duration > 0

      :telemetry.detach(start_id)
      :telemetry.detach(stop_id)
    end

    test "emits exception event on error", %{rt: rt} do
      pid = self()
      handler_id = "test-exception-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:denox, :eval, :exception],
        fn _event, measurements, metadata, _config ->
          send(pid, {:exception, measurements, metadata})
        end,
        nil
      )

      {:error, _} = Denox.eval(rt, "throw new Error('boom')")

      assert_receive {:exception, %{duration: duration}, %{type: :eval, kind: :error, reason: _}}
      assert is_integer(duration)

      :telemetry.detach(handler_id)
    end

    test "eval_ts emits with type :eval_ts", %{rt: rt} do
      pid = self()
      handler_id = "test-eval-ts-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:denox, :eval, :stop],
        fn _event, _measurements, metadata, _config ->
          send(pid, {:type, metadata.type})
        end,
        nil
      )

      {:ok, "42"} = Denox.eval_ts(rt, "const x: number = 42; x")

      assert_receive {:type, :eval_ts}

      :telemetry.detach(handler_id)
    end

    test "eval_async emits with type :eval_async", %{rt: rt} do
      pid = self()
      handler_id = "test-eval-async-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:denox, :eval, :stop],
        fn _event, _measurements, metadata, _config ->
          send(pid, {:type, metadata.type})
        end,
        nil
      )

      {:ok, "99"} = Task.await(Denox.eval_async(rt, "export default await Promise.resolve(99)"))

      assert_receive {:type, :eval_async}

      :telemetry.detach(handler_id)
    end

    test "eval_async_decode emits with type :eval_async_decode", %{rt: rt} do
      pid = self()
      handler_id = "test-eval-async-decode-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:denox, :eval, :stop],
        fn _event, _measurements, metadata, _config ->
          send(pid, {:type, metadata.type})
        end,
        nil
      )

      {:ok, 42} = Task.await(Denox.eval_async_decode(rt, "export default 42"))

      assert_receive {:type, :eval_async_decode}

      :telemetry.detach(handler_id)
    end

    test "call_async emits with type :call_async", %{rt: rt} do
      pid = self()
      handler_id = "test-call-async-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:denox, :eval, :stop],
        fn _event, _measurements, metadata, _config ->
          send(pid, {:type, metadata.type})
        end,
        nil
      )

      Denox.exec(rt, "globalThis.mul = async (n) => n * 3")
      {:ok, "15"} = Task.await(Denox.call_async(rt, "mul", [5]))

      assert_receive {:type, :call_async}

      :telemetry.detach(handler_id)
    end

    test "call emits with type :call", %{rt: rt} do
      pid = self()
      handler_id = "test-call-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:denox, :eval, :stop],
        fn _event, _measurements, metadata, _config ->
          send(pid, {:type, metadata.type})
        end,
        nil
      )

      Denox.exec(rt, "globalThis.add = (a, b) => a + b")
      {:ok, "7"} = Denox.call(rt, "add", [3, 4])

      assert_receive {:type, :call}

      :telemetry.detach(handler_id)
    end

    test "eval_ts_async emits with type :eval_ts_async", %{rt: rt} do
      pid = self()
      handler_id = "test-eval-ts-async-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:denox, :eval, :stop],
        fn _event, _measurements, metadata, _config ->
          send(pid, {:type, metadata.type})
        end,
        nil
      )

      {:ok, 99} = Task.await(Denox.eval_ts_async_decode(rt, "export default 99"))

      assert_receive {:type, :eval_ts_async_decode}

      :telemetry.detach(handler_id)
    end

    test "call_async_decode emits with type :call_async_decode", %{rt: rt} do
      pid = self()
      handler_id = "test-call-async-decode-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:denox, :eval, :stop],
        fn _event, _measurements, metadata, _config ->
          send(pid, {:type, metadata.type})
        end,
        nil
      )

      Denox.exec(rt, "globalThis.double = async (n) => n * 2")
      {:ok, 10} = Task.await(Denox.call_async_decode(rt, "double", [5]))

      assert_receive {:type, :call_async_decode}

      :telemetry.detach(handler_id)
    end

    test "eval_file_async emits with type :eval_file_async", %{rt: rt} do
      pid = self()
      handler_id = "test-eval-file-async-#{System.unique_integer([:positive])}"
      path = Path.join(System.tmp_dir!(), "test_eval_file_async_#{System.unique_integer()}.js")
      File.write!(path, "export default 42")

      :telemetry.attach(
        handler_id,
        [:denox, :eval, :stop],
        fn _event, _measurements, metadata, _config ->
          send(pid, {:type, metadata.type})
        end,
        nil
      )

      {:ok, "42"} = Task.await(Denox.eval_file_async(rt, path))

      assert_receive {:type, :eval_file_async}

      :telemetry.detach(handler_id)
      File.rm(path)
    end
  end
end
