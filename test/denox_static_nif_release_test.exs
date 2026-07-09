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

    assert release_yml =~
             ~s(GN_ARGS: "use_custom_libcxx=false treat_warnings_as_errors=false v8_enable_gdbjit=false")

    assert release_yml =~ ~s(EXTRA_GN_ARGS: "use_sysroot=false")
    assert release_yml =~ "docker run --rm"
    assert release_yml =~ "rust:1.88-alpine3.22"
    assert release_yml =~ ".github/scripts/build-static-nif.sh"
    refute release_yml =~ "libclang-rt-${clang_major}-dev"
    refute release_yml =~ "CLANG_BASE_PATH="
    refute release_yml =~ "libclang_rt.builtins"
    assert release_yml =~ "libdenox_nif.a"
    assert release_yml =~ "static-nif-"
  end

  test "release workflow builds and verifies static archives against musl link hazards" do
    release_yml = File.read!(Path.join(@repo_root, ".github/workflows/release.yml"))
    build_script = File.read!(Path.join(@repo_root, ".github/scripts/build-static-nif.sh"))

    assert release_yml =~ "docker run --rm"
    assert release_yml =~ "rust:1.88-alpine3.22"
    assert build_script =~ "apk add --no-cache"
    assert build_script =~ "build-base"
    assert build_script =~ "glib-dev"
    assert build_script =~ "linux-headers"
    assert build_script =~ "gn"
    assert build_script =~ "ninja"
    assert build_script =~ "pkgconf"
    refute build_script =~ ~r/\n  rust \\\n/
    refute build_script =~ ~r/\n  cargo \\\n/
    assert build_script =~ "rustc -vV"
    assert build_script =~ "cargo --version"
    assert build_script =~ "rust_host=\"$(rustc -vV | awk '/^host: / {print $2}')\""
    assert build_script =~ "x86_64-unknown-linux-musl) target_arch=\"x86_64\" ;;"
    assert build_script =~ "aarch64-unknown-linux-musl) target_arch=\"aarch64\" ;;"
    assert build_script =~ "\"${target_arch}\"-*-linux-musl"
    refute build_script =~ "rustc -vV | grep \"host: ${TARGET}\""
    refute build_script =~ "cargo build --release --target"
    assert build_script =~ "cargo build --release --features \"${feature}\""
    assert build_script =~ "target/release/libdenox_nif.a"
    assert build_script =~ "aarch64-linux-gnu-g++"
    assert build_script =~ "deno_core_icudata-"
    assert build_script =~ "third_party/icu/common/icudtl.dat"
    assert build_script =~ "objcopy"
    assert build_script =~ "__jit_debug_register_code"
    assert build_script =~ "__jit_debug_descriptor"

    assert release_yml =~ "nm -A -u"
    assert release_yml =~ "__libc_single_threaded"
    assert release_yml =~ "__memcpy_chk"
    assert release_yml =~ "mmap64"
    assert release_yml =~ "fopen64"
    assert release_yml =~ "backtrace_symbols"

    assert release_yml =~ "nm -A -g --defined-only"
    assert release_yml =~ "__jit_debug_register_code"
    assert release_yml =~ "__jit_debug_descriptor"
  end

  test "README documents static OTP linking inputs" do
    readme = File.read!(Path.join(@repo_root, "README.md"))

    assert readme =~ "--enable-static-nifs=/path/to/libdenox_nif.a:denox_nif"
    assert readme =~ "denox_nif_nif_init"
  end
end
