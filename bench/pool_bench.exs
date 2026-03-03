# Run with: mix run bench/pool_bench.exs

{:ok, rt} = Denox.runtime()
Denox.eval(rt, "1")

pool = :"bench_pool_#{:erlang.unique_integer([:positive])}"
{:ok, _} = Denox.Pool.start_link(name: pool, size: System.schedulers_online())
Denox.Pool.eval(pool, "1")

Benchee.run(
  %{
    "single runtime eval" => fn -> Denox.eval(rt, "1 + 2") end,
    "pool eval (sequential)" => fn -> Denox.Pool.eval(pool, "1 + 2") end,
    "pool eval (10 concurrent)" => fn ->
      1..10
      |> Enum.map(fn i -> Task.async(fn -> Denox.Pool.eval(pool, "#{i} * 2") end) end)
      |> Task.await_many()
    end,
    "pool eval (50 concurrent)" => fn ->
      1..50
      |> Enum.map(fn i -> Task.async(fn -> Denox.Pool.eval(pool, "#{i} * 2") end) end)
      |> Task.await_many()
    end
  },
  warmup: 2,
  time: 5,
  print: [configuration: false]
)
