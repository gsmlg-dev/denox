defmodule DenoxGlobalsTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, rt} = Denox.runtime()
    %{rt: rt}
  end

  describe "console" do
    test "console.log does not crash", %{rt: rt} do
      assert {:ok, _} = Denox.eval(rt, ~s[console.log("hello"); 1])
    end

    test "console methods exist", %{rt: rt} do
      code = """
      typeof console.log === "function" &&
      typeof console.warn === "function" &&
      typeof console.error === "function" &&
      typeof console.info === "function" &&
      typeof console.debug === "function" &&
      typeof console.dir === "function" &&
      typeof console.table === "function" &&
      typeof console.time === "function" &&
      typeof console.timeEnd === "function" &&
      typeof console.count === "function" &&
      typeof console.countReset === "function" &&
      typeof console.assert === "function" &&
      typeof console.group === "function" &&
      typeof console.groupEnd === "function" &&
      typeof console.clear === "function"
      """

      assert {:ok, "true"} = Denox.eval(rt, code)
    end

    test "console.assert does not crash on false", %{rt: rt} do
      assert {:ok, _} = Denox.eval(rt, ~s[console.assert(false, "test"); 1])
    end

    test "console.assert does not crash on true", %{rt: rt} do
      assert {:ok, _} = Denox.eval(rt, ~s[console.assert(true); 1])
    end
  end

  describe "atob/btoa" do
    test "btoa encodes to base64", %{rt: rt} do
      assert {:ok, ~s("SGVsbG8=")} = Denox.eval(rt, ~s[btoa("Hello")])
    end

    test "atob decodes from base64", %{rt: rt} do
      assert {:ok, ~s("Hello")} = Denox.eval(rt, ~s[atob("SGVsbG8=")])
    end

    test "btoa/atob roundtrip", %{rt: rt} do
      assert {:ok, ~s("Hello, World!")} =
               Denox.eval(rt, ~s[atob(btoa("Hello, World!"))])
    end

    test "btoa handles empty string", %{rt: rt} do
      assert {:ok, ~s("")} = Denox.eval(rt, ~s[btoa("")])
    end

    test "atob handles empty string", %{rt: rt} do
      assert {:ok, ~s("")} = Denox.eval(rt, ~s[atob("")])
    end
  end

  describe "performance" do
    test "performance.now returns a number", %{rt: rt} do
      assert {:ok, result} = Denox.eval(rt, "typeof performance.now()")
      assert result == ~s("number")
    end

    test "performance.now is monotonically increasing", %{rt: rt} do
      code = """
      var a = performance.now();
      var b = performance.now();
      b >= a
      """

      assert {:ok, "true"} = Denox.eval(rt, code)
    end

    test "performance.timeOrigin exists", %{rt: rt} do
      assert {:ok, result} = Denox.eval(rt, "typeof performance.timeOrigin")
      assert result == ~s("number")
    end
  end

  describe "navigator" do
    test "navigator.userAgent contains Deno", %{rt: rt} do
      assert {:ok, ua} = Denox.eval(rt, "navigator.userAgent")
      assert ua =~ "Deno"
    end

    test "navigator.language is set", %{rt: rt} do
      assert {:ok, lang} = Denox.eval(rt, "navigator.language")
      # MainWorker returns the system locale
      assert is_binary(lang)
    end

    test "navigator.hardwareConcurrency is a number", %{rt: rt} do
      assert {:ok, result} = Denox.eval(rt, "navigator.hardwareConcurrency")
      {n, ""} = Integer.parse(result)
      assert n >= 1
    end
  end

  describe "structuredClone" do
    test "clones objects", %{rt: rt} do
      code = """
      var obj = {a: 1, b: [2, 3]};
      var clone = structuredClone(obj);
      clone.a === 1 && clone.b[0] === 2 && clone.b[1] === 3
      """

      assert {:ok, "true"} = Denox.eval(rt, code)
    end

    test "clone is independent of original", %{rt: rt} do
      code = """
      var obj = {a: 1};
      var clone = structuredClone(obj);
      clone.a = 99;
      obj.a === 1
      """

      assert {:ok, "true"} = Denox.eval(rt, code)
    end
  end

  describe "queueMicrotask" do
    test "queueMicrotask exists", %{rt: rt} do
      assert {:ok, result} = Denox.eval(rt, "typeof queueMicrotask")
      assert result == ~s("function")
    end
  end

  describe "crypto" do
    test "crypto.getRandomValues fills a Uint8Array", %{rt: rt} do
      code = """
      var arr = new Uint8Array(16);
      crypto.getRandomValues(arr);
      arr.some(function(v) { return v !== 0; })
      """

      assert {:ok, "true"} = Denox.eval(rt, code)
    end

    test "crypto.getRandomValues returns the same array", %{rt: rt} do
      code = """
      var arr = new Uint8Array(4);
      var result = crypto.getRandomValues(arr);
      result === arr
      """

      assert {:ok, "true"} = Denox.eval(rt, code)
    end

    test "crypto.randomUUID returns a valid UUID v4", %{rt: rt} do
      code = """
      var uuid = crypto.randomUUID();
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(uuid)
      """

      assert {:ok, "true"} = Denox.eval(rt, code)
    end

    test "crypto.randomUUID returns unique values", %{rt: rt} do
      code = """
      var a = crypto.randomUUID();
      var b = crypto.randomUUID();
      a !== b
      """

      assert {:ok, "true"} = Denox.eval(rt, code)
    end
  end

  describe "Event / EventTarget" do
    test "Event constructor works", %{rt: rt} do
      code = """
      var e = new Event("click");
      e.type === "click" && e.bubbles === false && e.cancelable === false
      """

      assert {:ok, "true"} = Denox.eval(rt, code)
    end

    test "EventTarget dispatches events", %{rt: rt} do
      code = """
      var target = new EventTarget();
      var called = false;
      target.addEventListener("test", function() { called = true; });
      target.dispatchEvent(new Event("test"));
      called
      """

      assert {:ok, "true"} = Denox.eval(rt, code)
    end

    test "removeEventListener works", %{rt: rt} do
      code = """
      var target = new EventTarget();
      var count = 0;
      var handler = function() { count++; };
      target.addEventListener("test", handler);
      target.dispatchEvent(new Event("test"));
      target.removeEventListener("test", handler);
      target.dispatchEvent(new Event("test"));
      count === 1
      """

      assert {:ok, "true"} = Denox.eval(rt, code)
    end
  end

  describe "AbortController" do
    test "AbortController creates a signal", %{rt: rt} do
      code = """
      var ac = new AbortController();
      ac.signal.aborted === false
      """

      assert {:ok, "true"} = Denox.eval(rt, code)
    end

    test "abort() sets signal.aborted to true", %{rt: rt} do
      code = """
      var ac = new AbortController();
      ac.abort();
      ac.signal.aborted === true
      """

      assert {:ok, "true"} = Denox.eval(rt, code)
    end

    test "abort fires event on signal", %{rt: rt} do
      code = """
      var ac = new AbortController();
      var fired = false;
      ac.signal.addEventListener("abort", function() { fired = true; });
      ac.abort();
      fired
      """

      assert {:ok, "true"} = Denox.eval(rt, code)
    end

    test "AbortSignal.abort() returns an aborted signal", %{rt: rt} do
      code = """
      var signal = AbortSignal.abort();
      signal.aborted === true
      """

      assert {:ok, "true"} = Denox.eval(rt, code)
    end
  end

  describe "DOMException" do
    test "DOMException constructor works", %{rt: rt} do
      code = """
      var e = new DOMException("test error", "AbortError");
      e.message === "test error" && e.name === "AbortError"
      """

      assert {:ok, "true"} = Denox.eval(rt, code)
    end
  end

  describe "TextEncoder / TextDecoder" do
    test "TextEncoder exists", %{rt: rt} do
      assert {:ok, result} = Denox.eval(rt, "typeof TextEncoder")
      assert result == ~s("function")
    end

    test "TextDecoder exists", %{rt: rt} do
      assert {:ok, result} = Denox.eval(rt, "typeof TextDecoder")
      assert result == ~s("function")
    end

    test "TextEncoder/TextDecoder roundtrip", %{rt: rt} do
      code = """
      var enc = new TextEncoder();
      var dec = new TextDecoder();
      dec.decode(enc.encode("hello"))
      """

      assert {:ok, ~s("hello")} = Denox.eval(rt, code)
    end
  end

  describe "fetch" do
    test "fetch global exists", %{rt: rt} do
      assert {:ok, ~s("function")} = Denox.eval(rt, "typeof fetch")
    end

    test "Headers class works", %{rt: rt} do
      code = """
      var h = new Headers({"Content-Type": "text/plain", "X-Custom": "test"});
      h.get("content-type")
      """

      assert {:ok, ~s("text/plain")} = Denox.eval(rt, code)
    end

    test "Headers append combines values", %{rt: rt} do
      code = """
      var h = new Headers();
      h.append("Accept", "text/html");
      h.append("Accept", "application/json");
      h.get("accept")
      """

      assert {:ok, ~s("text/html, application/json")} = Denox.eval(rt, code)
    end

    test "Request class works", %{rt: rt} do
      code = """
      var req = new Request("https://example.com", { method: "POST" });
      req.method + " " + req.url
      """

      # MainWorker normalizes URLs, adding trailing slash
      assert {:ok, result} = Denox.eval(rt, code)
      assert result =~ "POST https://example.com"
    end

    test "Response class works", %{rt: rt} do
      code = """
      var resp = new Response("hello", { status: 200, statusText: "OK" });
      resp.ok && resp.status === 200 && resp.statusText === "OK"
      """

      assert {:ok, "true"} = Denox.eval(rt, code)
    end

    @tag :network
    test "fetch GET returns status", %{rt: rt} do
      task =
        Denox.eval_async(rt, "export default (await fetch('https://httpbin.org/get')).status")

      assert {:ok, "200"} = Task.await(task, 30_000)
    end

    @tag :network
    test "fetch response text() works", %{rt: rt} do
      code = """
      const resp = await fetch('https://httpbin.org/get');
      export default (await resp.text()).includes('httpbin')
      """

      task = Denox.eval_async(rt, code)
      assert {:ok, "true"} = Task.await(task, 30_000)
    end

    @tag :network
    test "fetch response json() works", %{rt: rt} do
      code = """
      const resp = await fetch('https://httpbin.org/get');
      const data = await resp.json();
      export default typeof data.url === 'string'
      """

      task = Denox.eval_async(rt, code)
      assert {:ok, "true"} = Task.await(task, 30_000)
    end

    @tag :network
    test "fetch response headers accessible", %{rt: rt} do
      code = """
      const resp = await fetch('https://httpbin.org/get');
      export default resp.headers.has('content-type')
      """

      task = Denox.eval_async(rt, code)
      assert {:ok, "true"} = Task.await(task, 30_000)
    end

    test "fetch rejects on invalid URL", %{rt: rt} do
      task = Denox.eval_async(rt, "export default await fetch('not-a-url')")
      assert {:error, _} = Task.await(task, 10_000)
    end
  end

  describe "URL / URLSearchParams" do
    test "URL constructor works", %{rt: rt} do
      code = """
      var url = new URL("https://example.com/path?q=1");
      url.hostname
      """

      assert {:ok, ~s("example.com")} = Denox.eval(rt, code)
    end

    test "URLSearchParams works", %{rt: rt} do
      code = """
      var p = new URLSearchParams("a=1&b=2");
      p.get("a")
      """

      assert {:ok, ~s("1")} = Denox.eval(rt, code)
    end
  end

  describe "Deno namespace" do
    test "Deno object is available", %{rt: rt} do
      assert {:ok, ~s("object")} = Denox.eval(rt, "typeof Deno")
    end

    test "Deno.version reports deno/v8/typescript", %{rt: rt} do
      assert {:ok, version} = Denox.eval_decode(rt, "Deno.version")
      assert is_binary(version["deno"])
      assert is_binary(version["v8"])
      assert is_binary(version["typescript"])
    end

    test "Deno.pid is a positive integer", %{rt: rt} do
      assert {:ok, pid_str} = Denox.eval(rt, "Deno.pid")
      assert {pid, ""} = Integer.parse(pid_str)
      assert pid > 0
    end

    test "Deno.env.get returns environment variable", %{rt: rt} do
      :ok = Denox.exec(rt, ~s[Deno.env.set("DENOX_TEST_VAR", "hello_denox")])
      assert {:ok, ~s("hello_denox")} = Denox.eval(rt, ~s[Deno.env.get("DENOX_TEST_VAR")])
    end

    test "Deno.env.toObject returns object", %{rt: rt} do
      assert {:ok, env} = Denox.eval_decode(rt, "Deno.env.toObject()")
      assert is_map(env)
    end

    test "Deno.args is an array", %{rt: rt} do
      assert {:ok, "true"} = Denox.eval(rt, "Array.isArray(Deno.args)")
    end

    test "Deno.build reports platform info", %{rt: rt} do
      assert {:ok, build} = Denox.eval_decode(rt, "Deno.build")
      assert is_binary(build["os"])
      assert is_binary(build["arch"])
      assert is_binary(build["target"])
    end

    test "Deno.readTextFileSync reads a file", %{rt: rt} do
      path = Path.join(System.tmp_dir!(), "denox_test_#{System.unique_integer([:positive])}.txt")
      File.write!(path, "test content")

      on_exit(fn -> File.rm(path) end)

      code = ~s[Deno.readTextFileSync("#{path}")]
      assert {:ok, ~s("test content")} = Denox.eval(rt, code)
    end

    test "Deno.writeTextFileSync writes a file" do
      {:ok, rt} =
        Denox.runtime(
          permissions: [allow_write: [System.tmp_dir!()], allow_read: [System.tmp_dir!()]]
        )

      path =
        Path.join(System.tmp_dir!(), "denox_write_test_#{System.unique_integer([:positive])}.txt")

      on_exit(fn -> File.rm(path) end)

      code = ~s[Deno.writeTextFileSync("#{path}", "written by deno"); "ok"]
      assert {:ok, ~s("ok")} = Denox.eval(rt, code)
      assert File.read!(path) == "written by deno"
    end
  end

  describe "Deno permissions enforcement" do
    test "deny_all mode blocks file reads" do
      {:ok, rt} = Denox.runtime(permissions: :none)
      path = Path.join(System.tmp_dir!(), "test.txt")
      File.write!(path, "secret")
      on_exit(fn -> File.rm(path) end)

      assert {:error, msg} = Denox.eval(rt, ~s[Deno.readTextFileSync("#{path}")])
      assert msg =~ "read access"
    end

    test "deny_all mode blocks env access" do
      {:ok, rt} = Denox.runtime(permissions: :none)

      assert {:error, msg} = Denox.eval(rt, ~s[Deno.env.get("HOME")])
      assert msg =~ "env access"
    end

    test "granular allow_read permits specific paths" do
      tmp = System.tmp_dir!()
      {:ok, rt} = Denox.runtime(permissions: [allow_read: [tmp]])
      path = Path.join(tmp, "denox_granular_#{System.unique_integer([:positive])}.txt")
      File.write!(path, "allowed")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, ~s("allowed")} = Denox.eval(rt, ~s[Deno.readTextFileSync("#{path}")])
    end
  end
end
