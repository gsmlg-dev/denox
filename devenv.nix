{ pkgs, lib, config, inputs, ... }:

let
  pkgs-stable = import inputs.nixpkgs-stable { system = pkgs.stdenv.system; };
in
{
  # Project metadata
  name = "denox";

  # Development tools
  packages = with pkgs-stable; [
    # Frontend build tools (NixOS-compatible binaries)
    alejandra
    git
    figlet
    lolcat
    tailwindcss_4

    # Deno runtime (for mix denox.install, denox.add, denox.remove)
    deno
  ] ++ lib.optionals pkgs.stdenv.isLinux [
    inotify-tools
  ];

  # Language configuration
  languages.elixir.enable = true;

  # Rust (for compiling native/denox_nif/ Rustler NIF)
  languages.rust.enable = true;

  # JavaScript / Bun
  languages.javascript.enable = true;
  languages.javascript.bun.enable = true;
  languages.javascript.bun.package = pkgs-stable.bun;

  # Environment variables
  env = {
    # Asset tooling — tells Mix hex packages to use Nix-managed binaries
    MIX_BUN_PATH = lib.getExe pkgs-stable.bun;
    MIX_TAILWIND_PATH = lib.getExe pkgs-stable.tailwindcss_4;

    # Build NIF from source (we have the Rust toolchain)
    DENOX_BUILD = "true";

    # Application
    MIX_ENV = "dev";
    SECRET_KEY_BASE = lib.mkDefault "dev-secret-key-base-change-in-production";

    # Phoenix
    PHX_HOST = "localhost";
    PHX_PORT = "4767";

    # Development flags
    ELIXIR_ERL_OPTIONS = "+sbwt none +sbwtdcpu none +sbwtdio none";
  };

  # Scripts for common tasks
  scripts = {
    hello.exec = ''
      figlet -w 120 $GREET | lolcat
    '';

      # Testing (MIX_ENV must be overridden since devenv sets it to "dev")
    test-all.exec = ''
      MIX_ENV=test mix test "$@"
    '';

    test-watch.exec = ''
      MIX_ENV=test mix test.watch "$@"
    '';
    
    # Code quality
    format.exec = ''
      mix format
    '';
    
    lint.exec = ''
      mix credo --strict
    '';
    
    quality.exec = ''
      mix format --check-formatted
      mix credo --strict
      mix dialyzer
    '';
    
    # Generate secrets
    gen-secret.exec = ''
      mix phx.gen.secret
    '';
    
    # Interactive shell
    console.exec = ''
      iex -S mix
    '';
  };

  # Enter shell hooks
  enterShell = ''
    hello
  '';
}
