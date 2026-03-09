import Config

config :denox_example, DenoxExampleWeb.Endpoint,
  http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: 4767],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dev_secret_key_base_at_least_64_bytes_long_for_phoenix_sessions_to_work_properly_ok",
  watchers: [
    tailwind: {Tailwind, :install_and_run, [:denox_example, ~w(--watch)]},
    bun: {Bun, :install_and_run, [:denox_example, ~w(--sourcemap=inline --watch)]}
  ]

config :denox_example, DenoxExampleWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/denox_example_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
