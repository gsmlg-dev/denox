defmodule DenoxExampleWeb.PlaygroundLive do
  use DenoxExampleWeb, :live_view

  @examples %{
    "arithmetic" => {"1 + 2 * 3 + 10 / 2", "js", "sync"},
    "objects" => {~s|({name: "Denox", version: 1, features: ["JS", "TS", "ESM"]})|, "js", "sync"},
    "typescript" => {"const x: number = 42;\nconst y: string = `Value is ${x}`;\ny", "ts", "sync"},
    "interfaces" => {"""
    interface User {
      name: string;
      age: number;
      active: boolean;
    }

    const user: User = {
      name: "Alice",
      age: 30,
      active: true
    };

    user\
    """, "ts", "sync"},
    "promises" => {"return await Promise.resolve(42)", "js", "async"},
    "async_ts" => {"""
    const delay = (ms: number): Promise<string> =>
      new Promise(resolve =>
        setTimeout(() => resolve(`waited ${ms}ms`), ms)
      );

    return await delay(100)\
    """, "ts", "async"},
    "fibonacci" => {"""
    function fib(n) {
      if (n <= 1) return n;
      return fib(n - 1) + fib(n - 2);
    }
    fib(20)\
    """, "js", "sync"},
    "array_ops" => {"""
    const data = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    ({
      sum: data.reduce((a, b) => a + b, 0),
      evens: data.filter(x => x % 2 === 0),
      doubled: data.map(x => x * 2),
      max: Math.max(...data)
    })\
    """, "js", "sync"}
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok, rt} = Denox.runtime()

    {:ok,
     assign(socket,
       page_title: "Playground",
       runtime: rt,
       code: "1 + 2",
       language: "js",
       mode: "sync",
       result: nil,
       result_status: nil,
       history: [],
       running: false,
       examples: @examples
     )}
  end

  @impl true
  def handle_event("update_code", %{"code" => code}, socket) do
    {:noreply, assign(socket, :code, code)}
  end

  def handle_event("set_language", %{"language" => language}, socket) do
    {:noreply, assign(socket, :language, language)}
  end

  def handle_event("set_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :mode, mode)}
  end

  def handle_event("run", _params, socket) do
    %{runtime: rt, code: code, language: language, mode: mode} = socket.assigns

    result =
      case {language, mode} do
        {"js", "sync"} -> Denox.eval(rt, code)
        {"ts", "sync"} -> Denox.eval_ts(rt, code)
        {"js", "async"} -> Denox.eval_async(rt, code)
        {"ts", "async"} -> Denox.eval_ts_async(rt, code)
      end

    {status, output} =
      case result do
        {:ok, value} -> {:ok, value}
        {:error, msg} -> {:error, msg}
      end

    entry = %{
      code: code,
      language: language,
      mode: mode,
      status: status,
      output: output,
      timestamp: DateTime.utc_now()
    }

    history = [entry | socket.assigns.history] |> Enum.take(10)

    {:noreply,
     assign(socket,
       result: output,
       result_status: status,
       history: history
     )}
  end

  def handle_event("load_example", %{"name" => name}, socket) do
    case Map.get(@examples, name) do
      {code, language, mode} ->
        {:noreply, assign(socket, code: code, language: language, mode: mode)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("clear_history", _params, socket) do
    {:noreply, assign(socket, :history, [])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- Example Snippets --%>
      <div>
        <h3 class="text-sm font-semibold text-base-content/70 mb-2">Examples</h3>
        <div class="flex flex-wrap gap-2">
          <.dm_btn
            :for={{name, _} <- @examples}
            variant="outline"
            size="sm"
            phx-click="load_example"
            phx-value-name={name}
          >
            {name |> String.replace("_", " ") |> String.capitalize()}
          </.dm_btn>
        </div>
      </div>

      <%!-- Code Editor --%>
      <div class="rounded-lg border border-base-300 bg-base-100 shadow-sm overflow-hidden">
        <div class="px-4 py-3 border-b border-base-300 font-semibold text-sm">Code</div>
        <form phx-change="update_code" phx-submit="run">
          <textarea
            name="code"
            rows="10"
            class="w-full font-mono text-sm bg-base-200 text-base-content p-4 border-0 focus:outline-none resize-y"
            phx-debounce="300"
          >{@code}</textarea>
        </form>
        <div class="flex items-center gap-4 px-4 py-3 border-t border-base-300">
          <%!-- Language Toggle --%>
          <div class="flex items-center gap-2">
            <span class="text-sm font-medium">Lang:</span>
            <.dm_btn
              variant={if @language == "js", do: "primary", else: "outline"}
              size="sm"
              phx-click="set_language"
              phx-value-language="js"
            >
              JS
            </.dm_btn>
            <.dm_btn
              variant={if @language == "ts", do: "primary", else: "outline"}
              size="sm"
              phx-click="set_language"
              phx-value-language="ts"
            >
              TS
            </.dm_btn>
          </div>

          <%!-- Mode Toggle --%>
          <div class="flex items-center gap-2">
            <span class="text-sm font-medium">Mode:</span>
            <.dm_btn
              variant={if @mode == "sync", do: "primary", else: "outline"}
              size="sm"
              phx-click="set_mode"
              phx-value-mode="sync"
            >
              Sync
            </.dm_btn>
            <.dm_btn
              variant={if @mode == "async", do: "primary", else: "outline"}
              size="sm"
              phx-click="set_mode"
              phx-value-mode="async"
            >
              Async
            </.dm_btn>
          </div>

          <div class="flex-1" />

          <%!-- Run Button --%>
          <.dm_btn variant="primary" phx-click="run">
            Run
          </.dm_btn>
        </div>
      </div>

      <%!-- Result --%>
      <div :if={@result} class={[
        "rounded-lg border-2 p-4",
        if(@result_status == :ok, do: "border-success bg-success/5", else: "border-error bg-error/5")
      ]}>
        <div class="flex items-center gap-2 mb-2">
          <.dm_badge variant={if @result_status == :ok, do: "success", else: "error"}>
            {if @result_status == :ok, do: "Success", else: "Error"}
          </.dm_badge>
        </div>
        <pre class="font-mono text-sm whitespace-pre-wrap break-words">{@result}</pre>
      </div>

      <%!-- History --%>
      <div :if={@history != []}>
        <div class="flex items-center justify-between mb-2">
          <h3 class="text-sm font-semibold text-base-content/70">History</h3>
          <.dm_btn variant="ghost" size="sm" phx-click="clear_history">
            Clear
          </.dm_btn>
        </div>
        <.dm_accordion id="history-accordion">
          <:item
            :for={{entry, idx} <- Enum.with_index(@history)}
            value={"history-#{idx}"}
            header={"#{String.upcase(entry.language)} #{entry.mode} - #{if entry.status == :ok, do: "OK", else: "Error"}"}
          >
            <pre class="font-mono text-xs bg-base-200 p-2 rounded mb-2 whitespace-pre-wrap">{entry.code}</pre>
            <div class={[
              "font-mono text-xs p-2 rounded",
              if(entry.status == :ok, do: "bg-success/10", else: "bg-error/10")
            ]}>
              {entry.output}
            </div>
          </:item>
        </.dm_accordion>
      </div>
    </div>
    """
  end
end
