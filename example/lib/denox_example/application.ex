defmodule DenoxExample.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DenoxExampleWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:denox_example, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: DenoxExample.PubSub},
      DenoxExampleWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: DenoxExample.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    DenoxExampleWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
