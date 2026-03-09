import Config

config :denox_example, DenoxExampleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4769],
  secret_key_base: "test_secret_key_base_at_least_64_bytes_long_for_phoenix_sessions_to_work_properly_ok",
  server: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, :enable_expensive_runtime_checks, true
