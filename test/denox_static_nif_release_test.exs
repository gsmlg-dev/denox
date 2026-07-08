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

    assert release_yml =~ "build_static_nif"
    assert release_yml =~ "x86_64-unknown-linux-musl"
    assert release_yml =~ "aarch64-unknown-linux-musl"
    assert release_yml =~ "libdenox_nif.a"
    assert release_yml =~ "static-nif-"
  end

  test "README documents static OTP linking inputs" do
    readme = File.read!(Path.join(@repo_root, "README.md"))

    assert readme =~ "--enable-static-nifs=/path/to/libdenox_nif.a:denox_nif"
    assert readme =~ "denox_nif_nif_init"
  end
end
