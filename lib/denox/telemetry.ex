defmodule Denox.Telemetry do
  @moduledoc false

  @doc false
  @spec span(atom(), (-> {:ok, term()} | {:error, term()})) :: {:ok, term()} | {:error, term()}
  def span(type, fun) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:denox, :eval, :start],
      %{system_time: System.system_time()},
      %{type: type}
    )

    case fun.() do
      {:ok, result} ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:denox, :eval, :stop],
          %{duration: duration},
          %{type: type}
        )

        {:ok, result}

      {:error, reason} = error ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:denox, :eval, :exception],
          %{duration: duration},
          %{type: type, kind: :error, reason: reason}
        )

        error
    end
  end
end
