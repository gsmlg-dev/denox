defmodule DenoxExampleWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint DenoxExampleWeb.Endpoint

      use DenoxExampleWeb, :verified_routes
      import Plug.Conn
      import Phoenix.ConnTest
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
