# Run with: mix run bench/denox_bench.exs

{:ok, rt} = Denox.runtime()
{:ok, rt_sandbox} = Denox.runtime(sandbox: true)

# Pre-warm runtimes
Denox.eval(rt, "1")
Denox.eval(rt_sandbox, "1")

# Set up a function for call benchmarks
Denox.exec(rt, "globalThis.double = (n) => n * 2")

Benchee.run(
  %{
    "eval (simple arithmetic)" => fn -> Denox.eval(rt, "1 + 2") end,
    "eval (object creation)" => fn -> Denox.eval(rt, "({a: 1, b: 'hello', c: [1,2,3]})") end,
    "eval_ts (typed)" => fn -> Denox.eval_ts(rt, "const x: number = 42; x") end,
    "eval_async (promise)" => fn -> Denox.eval_async(rt, "return await Promise.resolve(42)") end,
    "eval_decode (JSON)" => fn -> Denox.eval_decode(rt, "({a: 1, b: 2})") end,
    "call (function)" => fn -> Denox.call(rt, "double", [21]) end,
    "exec (no return)" => fn -> Denox.exec(rt, "1 + 1") end,
    "eval sandbox (arithmetic)" => fn -> Denox.eval(rt_sandbox, "1 + 2") end
  },
  warmup: 2,
  time: 5,
  print: [configuration: false]
)
