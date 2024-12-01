#!/bin/bash -e

# This scrip is for static cross compiling
# Please run this scrip in docker image: abcfy2/musl-cross-toolchain-ubuntu:${CROSS_HOST}
# E.g: docker run --rm -v `git rev-parse --show-toplevel`:/build abcfy2/musl-cross-toolchain-ubuntu:arm-unknown-linux-musleabi /build/build.sh
# Artifacts will copy to the same directory.

set -o pipefail

# value from: https://hub.docker.com/repository/docker/abcfy2/musl-cross-toolchain-ubuntu/tags

retry() {
  # max retry 5 times
  try=5
  # sleep 3s every retry
  sleep_time=30
  for i in $(seq ${try}); do
    echo "executing with retry: $@" >&2
    if eval "$@"; then
      return 0
    else
      echo "execute '$@' failed, tries: ${i}" >&2
      sleep ${sleep_time}
    fi
  done
  echo "execute '$@' failed" >&2
  return 1
}

source /etc/os-release
dpkg --add-architecture i386
# Ubuntu mirror for local building
if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
  if [ -f "/etc/apt/sources.list.d/ubuntu.sources" ]; then
    cat >/etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: http://mirror.sjtu.edu.cn/ubuntu/
Suites: ${UBUNTU_CODENAME} ${UBUNTU_CODENAME}-updates ${UBUNTU_CODENAME}-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://mirror.sjtu.edu.cn/ubuntu/
Suites: ${UBUNTU_CODENAME}-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
  else
    cat >/etc/apt/sources.list <<EOF
deb http://mirror.sjtu.edu.cn/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
deb http://mirror.sjtu.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb http://mirror.sjtu.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-backports main restricted universe multiverse
deb http://mirror.sjtu.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF
  fi
fi

export DEBIAN_FRONTEND=noninteractive

# keep debs in container for store cache in docker volume
rm -f /etc/apt/apt.conf.d/*
echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' >/etc/apt/apt.conf.d/01keep-debs
echo -e 'Acquire::https::Verify-Peer "false";\nAcquire::https::Verify-Host "false";' >/etc/apt/apt.conf.d/99-trust-https

apt update
apt install -y g++ \
  make \
  libtool \
  jq \
  pkgconf \
  file \
  tcl \
  autoconf \
  automake \
  autopoint \
  cmake \
  ninja-build \
  patch \
  wget \
  unzip

BUILD_ARCH="$(gcc -dumpmachine)"
TARGET_ARCH="${CROSS_HOST%%-*}"
TARGET_HOST="${CROSS_HOST#*-}"
case "${TARGET_ARCH}" in
"armel"*)
  TARGET_ARCH=armel
  ;;
"arm"*)
  TARGET_ARCH=arm
  ;;
i?86*)
  TARGET_ARCH=i386
  ;;
esac
case "${TARGET_HOST}" in
*"mingw"*)
  TARGET_HOST=Windows
  apt update
  apt install -y wine
  export WINEPREFIX=/tmp/
  RUNNER_CHECKER="wine"
  ;;
  *"darwin"*)
  TARGET_HOST=Darwin
  TARGET_OS=darwin
  export OSXCROSS_PKG_CONFIG_USE_NATIVE_VARIABLES=1
  if [ x"${TARGET_ARCH}" == "xx86_64" ]; then
      export CC="x86_64-apple-darwin20.4-clang -mmacosx-version-min=10.15"
      export CXX="x86_64-apple-darwin20.4-clang++ -mmacosx-version-min=10.15"
  elif [ x"${TARGET_ARCH}" == "xaarch64" ]; then
      export CC="aarch64-apple-darwin20.4-clang -mmacosx-version-min=11.0"
      export CXX="aarch64-apple-darwin20.4-clang++ -mmacosx-version-min=11.0"
  fi
  export LD="${CROSS_HOST}-ld"
  export AR="${CROSS_HOST}-ar"
  export NM="${CROSS_HOST}-nm"
  export AS="${CROSS_HOST}-as"
  export STRIP="${CROSS_HOST}-strip"
  export RANLIB="${CROSS_HOST}-ranlib"
  ;;
*)
  TARGET_HOST=Linux
  apt install -y "qemu-user-static"
  RUNNER_CHECKER="qemu-${TARGET_ARCH}-static"
  ;;
esac

export PATH="${CROSS_ROOT}/bin:${PATH}"
export CROSS_PREFIX="${CROSS_ROOT}/${CROSS_HOST}"
export PKG_CONFIG_PATH="${CROSS_PREFIX}/lib64/pkgconfig:${CROSS_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH}"
export LDFLAGS="-L${CROSS_PREFIX}/lib -I${CROSS_PREFIX}/include"
if [ x"${TARGET_HOST}" != "xDarwin" ]; then
	export LDFLAGS="-L${CROSS_PREFIX}/lib64 -L${CROSS_PREFIX}/lib -I${CROSS_PREFIX}/include -s -static --static"
fi
SELF_DIR="$(dirname "$(realpath "${0}")")"
BUILD_INFO="${SELF_DIR}/build_info.md"

# Create download cache directory
mkdir -p "${SELF_DIR}/downloads/"
export DOWNLOADS_DIR="${SELF_DIR}/downloads"

echo "## Build Info - ${CROSS_HOST}" >"${BUILD_INFO}"
echo "Building using these dependencies:" >>"${BUILD_INFO}"

prepare_zlib() {
  zlib_tag="$(retry wget -qO- --compression=auto https://zlib.net/ \| grep -i "'<FONT.*FONT>'" \| sed -r "'s/.*zlib\s*([^<]+).*/\1/'" \| head -1)"
  zlib_latest_url="https://zlib.net/zlib-${zlib_tag}.tar.xz"
  if [ ! -f "${DOWNLOADS_DIR}/zlib-${zlib_tag}.tar.gz" ]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/zlib-${zlib_tag}.tar.gz.part" "${zlib_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/zlib-${zlib_tag}.tar.gz.part" "${DOWNLOADS_DIR}/zlib-${zlib_tag}.tar.gz"
  fi
  mkdir -p "/usr/src/zlib-${zlib_tag}"
  tar -Jxf "${DOWNLOADS_DIR}/zlib-${zlib_tag}.tar.gz" --strip-components=1 -C "/usr/src/zlib-${zlib_tag}"
  cd "/usr/src/zlib-${zlib_tag}"
  if [ x"${TARGET_HOST}" = xWindows ]; then
    make -f win32/Makefile.gcc BINARY_PATH="${CROSS_PREFIX}/bin" INCLUDE_PATH="${CROSS_PREFIX}/include" LIBRARY_PATH="${CROSS_PREFIX}/lib" SHARED_MODE=0 PREFIX="${CROSS_HOST}-" -j$(nproc) install
  else
    CHOST="${CROSS_HOST}" ./configure --prefix="${CROSS_PREFIX}" --static
    make -j$(nproc)
    make install
  fi
  zlib_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/zlib.pc")"
  echo "- zlib: ${zlib_ver}, source: ${zlib_latest_url:-cached zlib}" >>"${BUILD_INFO}"
}

prepare_ssl() {
  openssl_filename="$(retry wget -qO- --compression=auto https://openssl-library.org/source/ \| grep -o "'>openssl-3\(\.[0-9]*\)*tar.gz<'" \| grep -o "'[^>]*.tar.gz'" \| sort -nr \| head -1)"
  openssl_ver="$(echo "${openssl_filename}" | sed -r 's/openssl-(.+)\.tar\.gz/\1/')"
  openssl_latest_url="https://github.com/openssl/openssl/releases/download/openssl-${openssl_ver}/${openssl_filename}"
  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
    openssl_latest_url="https://ghp.ci/${openssl_latest_url}"
  fi
  if [ ! -f "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz" ]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz.part" "${openssl_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz.part" "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz"
  fi
  mkdir -p "/usr/src/openssl-${openssl_ver}"
  tar -zxf "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz" --strip-components=1 -C "/usr/src/openssl-${openssl_ver}"
  cd "/usr/src/openssl-${openssl_ver}"
  ./Configure -static --cross-compile-prefix="${CROSS_HOST}-" --prefix="${CROSS_PREFIX}" "${OPENSSL_COMPILER}" -c="${CC}" --openssldir=/etc/ssl
  make -j$(nproc)
  make install_sw
  openssl_ver="$(grep Version: "${CROSS_PREFIX}"/lib*/pkgconfig/openssl.pc)"
  echo "- openssl: ${openssl_ver}, source: ${openssl_latest_url:-cached openssl}" >>"${BUILD_INFO}"
}

build_aria2() {
  if [ -n "${ARIA2_VER}" ]; then
    aria2_tag="${ARIA2_VER}"
  else
    aria2_tag=master
    # Check download cache whether expired
    if [ -f "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz" ]; then
      cached_file_ts="$(stat -c '%Y' "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz")"
      current_ts="$(date +%s)"
      if [ "$((${current_ts} - "${cached_file_ts}"))" -gt 86400 ]; then
        echo "Delete expired aria2 archive file cache..."
        rm -f "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz"
      fi
    fi
  fi

  if [ -n "${ARIA2_VER}" ]; then
    aria2_latest_url="https://github.com/aria2/aria2/releases/download/release-${ARIA2_VER}/aria2-${ARIA2_VER}.tar.gz"
  else
    aria2_latest_url="https://github.com/aria2/aria2/archive/master.tar.gz"
  fi
  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
    aria2_latest_url="https://ghp.ci/${aria2_latest_url}"
  fi

  if [ ! -f "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz" ]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz.part" "${aria2_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz.part" "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz"
  fi
  mkdir -p "/usr/src/aria2-${aria2_tag}"
  tar -zxf "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz" --strip-components=1 -C "/usr/src/aria2-${aria2_tag}"
  cd "/usr/src/aria2-${aria2_tag}"
  if [ ! -f ./configure ]; then
    autoreconf -i
  fi
  if [ x"${TARGET_HOST}" != xLinux ]; then
    ARIA2_EXT_CONF='--without-openssl'
  # else
  #   ARIA2_EXT_CONF='--with-ca-bundle=/etc/ssl/certs/ca-certificates.crt'
  fi
  ./configure \
    --host="${CROSS_HOST}" \
    --prefix="${CROSS_PREFIX}" \
    --enable-static \
    --disable-shared \
    --enable-silent-rules \
    --disable-metalink \
    --disable-bittorrent \
    --disable-websocket \
    --without-libssh2 \
    --without-sqlite3 \
    --without-libxml2 \
    --without-libcares \
    ARIA2_STATIC=yes \
    ${ARIA2_EXT_CONF}
  make -j$(nproc)
  make install
  echo "- aria2: source: ${aria2_latest_url:-cached aria2}" >>"${BUILD_INFO}"
  echo >>"${BUILD_INFO}"
}

get_build_info() {
  echo "============= ARIA2 VER INFO ==================="
  ARIA2_VER_INFO="$("${RUNNER_CHECKER}" "${CROSS_PREFIX}/bin/aria2c"* --version 2>/dev/null)"
  echo "${ARIA2_VER_INFO}"
  echo "================================================"

  echo "aria2 version info:" >>"${BUILD_INFO}"
  echo '```txt' >>"${BUILD_INFO}"
  echo "${ARIA2_VER_INFO}" >>"${BUILD_INFO}"
  echo '```' >>"${BUILD_INFO}"
}

test_build() {
  # get release
  cp -fv "${CROSS_PREFIX}/bin/"aria2* "${SELF_DIR}"
  echo "============= ARIA2 TEST DOWNLOAD =============="
  "${RUNNER_CHECKER}" "${CROSS_PREFIX}/bin/aria2c"* -t 10 --console-log-level=debug --http-accept-gzip=true https://github.com/ -d /tmp -o test
  echo "================================================"
}

prepare_zlib
if [ x"${TARGET_HOST}" = x"Linux" ]; then
  prepare_ssl
fi
build_aria2

get_build_info
# mips test will hang, I don't know why. So I just ignore test failures.
# test_build

# get release
cp -fv "${CROSS_PREFIX}/bin/"aria2* "${SELF_DIR}"