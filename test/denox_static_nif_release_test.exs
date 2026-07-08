defmodule Denox.StaticNifReleaseTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("..", __DIR__)

  test "native crate declares dynamic and static library outputs" do
    cargo_toml = File.read!(Path.join(@repo_root, "native/denox_nif/Cargo.toml"))

    assert cargo_toml =~ ~s(crate-type = ["cdylib", "staticlib"])
  end

  test "native crate exports the OTP static NIF init symbol" do
    lib_rs = File.read!(Path.join(@repo_root, "native/denox_nif/src/lib.rs"))

    assert lib_rs =~ "denox_nif_nif_init"
    assert lib_rs =~ "nif_init"
  end

  test "release workflow publishes Linux musl static NIF archives" do
    release_yml = File.read!(Path.join(@repo_root, ".github/workflows/release.yml"))

    assert release_yml =~ "cargo generate-lockfile --manifest-path native/denox_nif/Cargo.toml"
    assert release_yml =~ "native/denox_nif/Cargo.lock"
    assert release_yml =~ "build_static_nif"
    assert release_yml =~ "x86_64-unknown-linux-musl"
    assert release_yml =~ "aarch64-unknown-linux-musl"
    assert release_yml =~ "for attempt in 1 2 3"
    assert release_yml =~ "mix deps.get failed on attempt"
    assert release_yml =~ "ubuntu-22.04-arm"
    assert release_yml =~ ~s(V8_FROM_SOURCE: "1")
    assert release_yml =~ ~s(DISABLE_CLANG: "1")
    assert release_yml =~ ~s(GN_ARGS: "use_custom_libcxx=false treat_warnings_as_errors=false")
    assert release_yml =~ "g++"
    assert release_yml =~ "linux-libc-dev"
    assert release_yml =~ "linux/limits.h"
    assert release_yml =~ "CFLAGS=-isystem"
    refute release_yml =~ "libclang-rt-${clang_major}-dev"
    refute release_yml =~ "CLANG_BASE_PATH="
    refute release_yml =~ "libclang_rt.builtins"
    assert release_yml =~ "generate-ninja"
    assert release_yml =~ "ninja-build"
    assert release_yml =~ "GN=$(command -v gn)"
    assert release_yml =~ "NINJA=$(command -v ninja)"
    assert release_yml =~ "deno_core_icudata-"
    assert release_yml =~ "third_party/icu/common/icudtl.dat"
    assert release_yml =~ "libglib2.0-dev"
    assert release_yml =~ "libdenox_nif.a"
    assert release_yml =~ "static-nif-"
  end

  test "README documents static OTP linking inputs" do
    readme = File.read!(Path.join(@repo_root, "README.md"))

    assert readme =~ "--enable-static-nifs=/path/to/libdenox_nif.a:denox_nif"
    assert readme =~ "denox_nif_nif_init"
  end
end
