defmodule DenoxExampleWeb.Router do
  use DenoxExampleWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DenoxExampleWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", DenoxExampleWeb do
    pipe_through :browser

    live "/", PlaygroundLive, :index
  end
end
