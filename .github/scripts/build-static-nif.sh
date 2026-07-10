#!/bin/sh
set -eu

HOME="${HOME:-/root}"
export HOME

if ! grep -q '/v3.22/community' /etc/apk/repositories; then
  echo "https://dl-cdn.alpinelinux.org/alpine/v3.22/community" >> /etc/apk/repositories
fi

apk add --no-cache \
  binutils \
  build-base \
  clang20-dev \
  curl \
  git \
  glib-dev \
  gn \
  linux-headers \
  ninja \
  pkgconf \
  python3 \
  tar

rustc -vV
rust_host="$(rustc -vV | awk '/^host: / {print $2}')"
case "${TARGET}" in
  x86_64-unknown-linux-musl) target_arch="x86_64" ;;
  aarch64-unknown-linux-musl) target_arch="aarch64" ;;
  *)
    echo "Unsupported static NIF target: ${TARGET}" >&2
    exit 1
    ;;
esac

case "${rust_host}" in
  "${target_arch}"-*-linux-musl) ;;
  *)
    echo "Rust host ${rust_host} does not match musl target ${TARGET}" >&2
    exit 1
    ;;
esac

cargo --version
gn --version
ninja --version
pkg-config --modversion glib-2.0

if [ ! -e /usr/lib/libclang.so ]; then
  echo "Unable to locate /usr/lib/libclang.so for bindgen" >&2
  exit 1
fi

export LIBCLANG_PATH=/usr/lib

# Bindgen loads libclang with dlopen; musl build scripts with crt-static cannot.
if [ -n "${RUSTFLAGS:-}" ]; then
  export RUSTFLAGS="${RUSTFLAGS} -C target-feature=-crt-static"
else
  export RUSTFLAGS="-C target-feature=-crt-static"
fi

if [ "${TARGET}" = "aarch64-unknown-linux-musl" ]; then
  ln -sf "$(command -v gcc)" /usr/local/bin/aarch64-linux-gnu-gcc
  ln -sf "$(command -v g++)" /usr/local/bin/aarch64-linux-gnu-g++
  ln -sf "$(command -v ar)" /usr/local/bin/aarch64-linux-gnu-ar
  ln -sf "$(command -v nm)" /usr/local/bin/aarch64-linux-gnu-nm
  ln -sf "$(command -v readelf)" /usr/local/bin/aarch64-linux-gnu-readelf
fi

cargo fetch

cargo_home="${CARGO_HOME:-${HOME}/.cargo}"
registry_cache="${cargo_home}/registry/cache"
registry_src="${cargo_home}/registry/src"

unpack_registry_crate() {
  crate_pattern="$1"
  crate_file="$(find "${registry_cache}" -type f -name "${crate_pattern}.crate" | head -n 1)"

  if [ -z "${crate_file}" ]; then
    echo "Unable to locate ${crate_pattern}.crate in Cargo registry cache" >&2
    exit 1
  fi

  cache_dir="$(basename "$(dirname "${crate_file}")")"
  package_dir="$(basename "${crate_file}" .crate)"
  mkdir -p "${registry_src}/${cache_dir}"

  if [ ! -d "${registry_src}/${cache_dir}/${package_dir}" ]; then
    tar -xzf "${crate_file}" -C "${registry_src}/${cache_dir}"
  fi
}

unpack_registry_crate 'v8-*'
unpack_registry_crate 'deno_core_icudata-*'

v8_dir="$(find "${registry_src}" -type d -name 'v8-*' | head -n 1)"
icu_data="$(find "${registry_src}" -type f -path '*/deno_core_icudata-*/src/icudtl.dat' | head -n 1)"

if [ -z "${v8_dir}" ] || [ -z "${icu_data}" ]; then
  echo "Unable to locate rusty_v8 source or deno_core ICU data" >&2
  exit 1
fi

mkdir -p "${v8_dir}/third_party/icu/common"
cp "${icu_data}" "${v8_dir}/third_party/icu/common/icudtl.dat"

feature="nif_version_$(printf '%s' "${NIF_VERSION}" | tr '.' '_')"
cargo build --release --features "${feature},static_nif"

archive_dir="../../static-nifs/denox_nif-v${VERSION}-nif-${NIF_VERSION}-${TARGET}-static"
mkdir -p "${archive_dir}"
cp "target/release/libdenox_nif.a" "${archive_dir}/libdenox_nif.a"
objcopy \
  --localize-symbol=__jit_debug_register_code \
  --localize-symbol=__jit_debug_descriptor \
  "${archive_dir}/libdenox_nif.a"
tar -C "${archive_dir}" -czf "${archive_dir}.tar.gz" libdenox_nif.a
