import Config

config :denox_example,
  generators: [timestamp_type: :utc_datetime]

config :denox, :force_build, true

config :denox_example, DenoxExampleWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: DenoxExampleWeb.ErrorHTML, json: DenoxExampleWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: DenoxExample.PubSub,
  live_view: [signing_salt: "denox_playground"]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

config :bun,
  version: "1.3.4",
  denox_example: [
    args: ~w(build assets/js/app.js --outdir=priv/static/assets --external /fonts/* --external /images/*),
    cd: Path.expand("../", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "4.1.11",
  denox_example: [
    args: ~w(--input=assets/css/app.css --output=priv/static/assets/app.css),
    cd: Path.expand("../", __DIR__)
  ]

import_config "#{config_env()}.exs"
