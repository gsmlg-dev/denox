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
  cargo \
  curl \
  git \
  glib-dev \
  gn \
  linux-headers \
  ninja \
  pkgconf \
  python3 \
  rust \
  tar

rustc -vV
rustc -vV | grep "host: ${TARGET}"
cargo --version
gn --version
ninja --version
pkg-config --modversion glib-2.0

if [ "${TARGET}" = "aarch64-unknown-linux-musl" ]; then
  ln -sf "$(command -v gcc)" /usr/local/bin/aarch64-linux-gnu-gcc
  ln -sf "$(command -v g++)" /usr/local/bin/aarch64-linux-gnu-g++
  ln -sf "$(command -v ar)" /usr/local/bin/aarch64-linux-gnu-ar
  ln -sf "$(command -v nm)" /usr/local/bin/aarch64-linux-gnu-nm
  ln -sf "$(command -v readelf)" /usr/local/bin/aarch64-linux-gnu-readelf
fi

cargo fetch
v8_dir="$(find "${HOME}/.cargo/registry/src" -type d -name 'v8-*' | head -n 1)"
icu_data="$(find "${HOME}/.cargo/registry/src" -type f -path '*/deno_core_icudata-*/src/icudtl.dat' | head -n 1)"

if [ -z "${v8_dir}" ] || [ -z "${icu_data}" ]; then
  echo "Unable to locate rusty_v8 source or deno_core ICU data" >&2
  exit 1
fi

mkdir -p "${v8_dir}/third_party/icu/common"
cp "${icu_data}" "${v8_dir}/third_party/icu/common/icudtl.dat"

feature="nif_version_$(printf '%s' "${NIF_VERSION}" | tr '.' '_')"
cargo build --release --target "${TARGET}" --features "${feature}"

archive_dir="../../static-nifs/denox_nif-v${VERSION}-nif-${NIF_VERSION}-${TARGET}-static"
mkdir -p "${archive_dir}"
cp "target/${TARGET}/release/libdenox_nif.a" "${archive_dir}/libdenox_nif.a"
objcopy \
  --localize-symbol=__jit_debug_register_code \
  --localize-symbol=__jit_debug_descriptor \
  "${archive_dir}/libdenox_nif.a"
tar -C "${archive_dir}" -czf "${archive_dir}.tar.gz" libdenox_nif.a
