#!/usr/bin/env bash
#
# deploy.sh
#
# Builds a .deb of the nes-bundler bundler service for Debian 13 (trixie)
# inside a disposable debootstrap chroot. The chroot is cleaned up on exit.
#
# Inside the chroot, this also pre-builds SDL3 (static, per target) and
# embeds it in the .deb so the production host doesn't need X11/Wayland/
# ALSA/udev -dev packages.
#
# Usage:
#   chmod +x deploy.sh
#   sudo ./deploy.sh
#
# Environment variables (all optional):
#   PKG_NAME       (default: nes-bundler)
#   VERSION        (default: read from Cargo.toml)
#   PKG_REVISION   (default: 1)
#   ARCH           (default: dpkg --print-architecture)
#   SDL_VERSION    (default: 3.4.2 — matches sdl3-sys 0.6.1+SDL-3.4.2)
#   MAINTAINER     (default: Antoni Aloy Torrens <antoniat211@gmail.com>)
#   CHROOT_BASE    (default: /var/tmp)
#
# Output: dist/<pkg>_<version>-<rev>_<arch>.deb

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    exec sudo -E "$0" "$@"
fi

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_ROOT"

PKG_NAME="${PKG_NAME:-nes-bundler}"
VERSION="${VERSION:-$(awk -F'"' '/^version[[:space:]]*=/ {print $2; exit}' Cargo.toml)}"
PKG_REVISION="${PKG_REVISION:-1}"
ARCH="${ARCH:-$(dpkg --print-architecture)}"
SDL_VERSION="${SDL_VERSION:-3.4.2}"
MAINTAINER="${MAINTAINER:-Antoni Aloy Torrens <antoniat211@gmail.com>}"

if [[ -z "$VERSION" ]]; then
    echo "Could not derive VERSION from Cargo.toml; set VERSION=... and retry." >&2
    exit 1
fi

DESCRIPTION="nes-bundler ${VERSION} bundler service (Linux/Windows cross builds)"
DEB_FILE="${PKG_NAME}_${VERSION}-${PKG_REVISION}_${ARCH}.deb"
CHROOT_DIR="${CHROOT_BASE:-/var/tmp}/nes-bundler-build-$(head -c6 /dev/urandom | xxd -p)"
DIST_DIR="${PROJECT_ROOT}/dist"

mkdir -p "$DIST_DIR"

cleanup() {
    echo ">>> Cleaning up chroot..."
    umount "${CHROOT_DIR}/output"  2>/dev/null || true
    umount "${CHROOT_DIR}/source"  2>/dev/null || true
    umount "${CHROOT_DIR}/proc"    2>/dev/null || true
    umount "${CHROOT_DIR}/sys"     2>/dev/null || true
    umount "${CHROOT_DIR}/dev/pts" 2>/dev/null || true
    umount "${CHROOT_DIR}/dev"     2>/dev/null || true
    rm -rf "${CHROOT_DIR}"
}
trap cleanup EXIT INT TERM

echo "Building ${PKG_NAME} ${VERSION}-${PKG_REVISION} (${ARCH})"
echo "  SDL3:    ${SDL_VERSION} (prebuilt static, embedded)"
echo "  Project: ${PROJECT_ROOT}"
echo "  Output:  ${DIST_DIR}/${DEB_FILE}"
echo "  Chroot:  ${CHROOT_DIR}"
echo ""

if ! command -v debootstrap &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq debootstrap
fi

echo ">>> Bootstrapping Debian Trixie chroot..."
debootstrap --variant=minbase trixie "${CHROOT_DIR}" http://deb.debian.org/debian

mount -t proc proc "${CHROOT_DIR}/proc"
mount -t sysfs sys "${CHROOT_DIR}/sys"
mount --bind /dev "${CHROOT_DIR}/dev"
mount --bind /dev/pts "${CHROOT_DIR}/dev/pts"

mkdir -p "${CHROOT_DIR}/source" "${CHROOT_DIR}/output"
mount --bind -o ro "${PROJECT_ROOT}" "${CHROOT_DIR}/source"
mount --bind "${DIST_DIR}" "${CHROOT_DIR}/output"

cat > "${CHROOT_DIR}/build.sh" << 'BUILDEOF'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq

# Two distinct groups: (a) tools to assemble the .deb, (b) full SDL3 build deps.
# Group (b) is only used inside this chroot — it stays out of the final .deb.
apt-get install -y -qq --no-install-recommends \
    ruby ruby-dev rubygems \
    ca-certificates curl xz-utils \
    build-essential cmake pkg-config \
    mingw-w64 \
    \
    libx11-dev libxext-dev libxcursor-dev libxi-dev libxrandr-dev \
    libxss-dev libxkbcommon-dev libxfixes-dev \
    libwayland-dev wayland-protocols libdecor-0-dev \
    libasound2-dev libpulse-dev libpipewire-0.3-dev \
    libdbus-1-dev libudev-dev \
    libdrm-dev libgbm-dev libegl-dev libgl-dev \
    libibus-1.0-dev

if ! command -v fpm &>/dev/null; then
    gem install --no-document fpm
fi

# --- Pre-fetch zig + cargo-zigbuild -----------------------------------------
# Both get embedded in the .deb. Used here in the chroot to (re)compile SDL3
# against an old glibc, and reused by the bundler service at job time via
# `cargo zigbuild --target x86_64-unknown-linux-gnu.${GLIBC_TARGET}`, so the
# Linux binaries the service produces run on basically any distro from the
# last decade (CentOS 7 era and newer).

ZIG_VERSION="0.13.0"
CARGO_ZIGBUILD_VERSION="0.19.6"
GLIBC_TARGET="2.17"

echo ">>> Downloading zig ${ZIG_VERSION}..."
mkdir -p /opt/_vendor
curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /opt/_vendor
mv "/opt/_vendor/zig-linux-x86_64-${ZIG_VERSION}" /opt/_vendor/zig

echo ">>> Downloading cargo-zigbuild ${CARGO_ZIGBUILD_VERSION}..."
mkdir -p /opt/_vendor/bin
curl -fsSL "https://github.com/rust-cross/cargo-zigbuild/releases/download/v${CARGO_ZIGBUILD_VERSION}/cargo-zigbuild-v${CARGO_ZIGBUILD_VERSION}.x86_64-unknown-linux-musl.tar.gz" \
    | tar -xz -C /opt/_vendor/bin
chmod +x /opt/_vendor/bin/cargo-zigbuild

# Wrapper scripts so cmake (and any other build that expects a normal C/C++
# compiler) sees a single binary. zig cc/c++ is one executable that
# cross-compiles via -target; we bake the target in once here.
cat > /opt/_vendor/bin/zig-cc << EOF
#!/bin/sh
exec /opt/_vendor/zig/zig cc -target x86_64-linux-gnu.${GLIBC_TARGET} "\$@"
EOF
cat > /opt/_vendor/bin/zig-cxx << EOF
#!/bin/sh
exec /opt/_vendor/zig/zig c++ -target x86_64-linux-gnu.${GLIBC_TARGET} "\$@"
EOF
chmod +x /opt/_vendor/bin/zig-cc /opt/_vendor/bin/zig-cxx

export PATH="/opt/_vendor/bin:/opt/_vendor/zig:${PATH}"

# --- Pre-build SDL3 ---------------------------------------------------------
# Static archives + sdl3.pc for both targets. System backends (X11/Wayland/
# ALSA/pipewire/etc.) are compiled with *_SHARED=ON so SDL3 dlopens them at
# runtime on the *end user's* machine — the bundler service host itself
# never needs them.

SDL_VERSION="__SDL_VERSION__"
SDL_SRC="/tmp/SDL3-${SDL_VERSION}"

echo ">>> Downloading SDL ${SDL_VERSION}..."
curl -fsSL "https://github.com/libsdl-org/SDL/releases/download/release-${SDL_VERSION}/SDL3-${SDL_VERSION}.tar.gz" \
    | tar -xz -C /tmp

SDL_COMMON=(
    -DCMAKE_BUILD_TYPE=Release
    -DSDL_SHARED=OFF
    -DSDL_STATIC=ON
    -DSDL_TESTS=OFF
    -DSDL_EXAMPLES=OFF
    -DSDL_INSTALL_DOCS=OFF
    -DSDL_INSTALL_TESTS=OFF
    # Max compatibility — only the x86_64 ABI baseline (SSE/SSE2) is left on.
    -DSDL_SSE3=OFF
    -DSDL_SSE4_1=OFF
    -DSDL_SSE4_2=OFF
    -DSDL_AVX=OFF
    -DSDL_AVX2=OFF
    -DSDL_AVX512F=OFF
)

echo ">>> Building SDL3 (x86_64-unknown-linux-gnu, glibc ${GLIBC_TARGET} via zig cc)..."
# Compile SDL3 against the same old glibc the Rust binaries will target;
# otherwise the SDL3 .a carries symbol references like memcpy@GLIBC_2.34
# that won't resolve at runtime on older user systems.
cmake -S "$SDL_SRC" -B /tmp/build-sdl-linux \
    "${SDL_COMMON[@]}" \
    -DCMAKE_INSTALL_PREFIX=/tmp/sdl3-linux \
    -DCMAKE_C_COMPILER=/opt/_vendor/bin/zig-cc \
    -DCMAKE_CXX_COMPILER=/opt/_vendor/bin/zig-cxx \
    -DSDL_X11_XTEST=OFF \
    -DSDL_X11_SHARED=ON \
    -DSDL_WAYLAND_SHARED=ON \
    -DSDL_ALSA_SHARED=ON \
    -DSDL_PULSEAUDIO_SHARED=ON \
    -DSDL_PIPEWIRE_SHARED=ON \
    -DSDL_KMSDRM_SHARED=ON
cmake --build /tmp/build-sdl-linux --parallel
cmake --install /tmp/build-sdl-linux

echo ">>> Building SDL3 (x86_64-pc-windows-gnu, mingw cross)..."
cat > /tmp/mingw-toolchain.cmake << 'TC'
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_C_COMPILER   x86_64-w64-mingw32-gcc)
set(CMAKE_CXX_COMPILER x86_64-w64-mingw32-g++)
set(CMAKE_RC_COMPILER  x86_64-w64-mingw32-windres)
set(CMAKE_FIND_ROOT_PATH /usr/x86_64-w64-mingw32)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
TC

cmake -S "$SDL_SRC" -B /tmp/build-sdl-mingw \
    "${SDL_COMMON[@]}" \
    -DCMAKE_TOOLCHAIN_FILE=/tmp/mingw-toolchain.cmake \
    -DCMAKE_INSTALL_PREFIX=/tmp/sdl3-mingw
cmake --build /tmp/build-sdl-mingw --parallel
cmake --install /tmp/build-sdl-mingw

# --- Stage the .deb file tree -----------------------------------------------

STAGE="$(mktemp -d)"
SCRIPTS="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$SCRIPTS"' EXIT

install -d "$STAGE/opt/nesbundler"
tar -C /source \
    --exclude='./.git' \
    --exclude='./.github' \
    --exclude='./.env' \
    --exclude='./target' \
    --exclude='./dist' \
    --exclude='./docker-compose*.yml' \
    --exclude='./bundler/Dockerfile*' \
    --exclude='./bundler/install-packaging.sh' \
    --exclude='./deploy.sh' \
    -cf - . | tar -xf - -C "$STAGE/opt/nesbundler"

# Embed prebuilt SDL3 — what build.sh's PKG_CONFIG_PATH_<triple> points at.
install -d "$STAGE/opt/nesbundler/vendor/sdl3"
cp -a /tmp/sdl3-linux "$STAGE/opt/nesbundler/vendor/sdl3/linux"
cp -a /tmp/sdl3-mingw "$STAGE/opt/nesbundler/vendor/sdl3/mingw"

# Rewrite the absolute "prefix=" line in sdl3.pc so pkg-config resolves
# paths against the installed location, not /tmp/sdl3-{linux,mingw}.
sed -i "s|^prefix=.*|prefix=/opt/nesbundler/vendor/sdl3/linux|" \
    "$STAGE/opt/nesbundler/vendor/sdl3/linux/lib/pkgconfig/sdl3.pc"
sed -i "s|^prefix=.*|prefix=/opt/nesbundler/vendor/sdl3/mingw|" \
    "$STAGE/opt/nesbundler/vendor/sdl3/mingw/lib/pkgconfig/sdl3.pc"

# Embed zig + cargo-zigbuild. cargo-zigbuild is a cargo subcommand
# (PATH-discovered as `cargo-zigbuild`), and it shells out to `zig`, so both
# directories need to be on PATH at runtime — see /etc/nesbundler/default below.
install -d "$STAGE/opt/nesbundler/vendor/zig" "$STAGE/opt/nesbundler/vendor/bin"
cp -a /opt/_vendor/zig/. "$STAGE/opt/nesbundler/vendor/zig/"
install -m 0755 /opt/_vendor/bin/cargo-zigbuild "$STAGE/opt/nesbundler/vendor/bin/cargo-zigbuild"

# --- systemd unit -----------------------------------------------------------

install -d "$STAGE/lib/systemd/system"
cat > "$STAGE/lib/systemd/system/nesbundler.service" << 'UNIT'
[Unit]
Description=nes-bundler bundler service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=bundler
Group=bundler
WorkingDirectory=/opt/nesbundler
EnvironmentFile=/etc/nesbundler/default
ExecStart=/usr/bin/python3 -m uvicorn --host ${BUNDLER_HOST} --port ${BUNDLER_PORT} --proxy-headers --app-dir /opt/nesbundler/bundler server:app
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/nesbundler

[Install]
WantedBy=multi-user.target
UNIT

# Periodic janitor — purges expired download artifacts and old job dirs.
# Retention windows are tunable via /etc/nesbundler/default.
cat > "$STAGE/lib/systemd/system/nesbundler-cleanup.service" << 'UNIT'
[Unit]
Description=nes-bundler periodic cleanup (job + bundle retention)

[Service]
Type=oneshot
User=bundler
Group=bundler
EnvironmentFile=/etc/nesbundler/default
ExecStart=/usr/bin/python3 /opt/nesbundler/bundler/cleanup.py
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/nesbundler
UNIT

cat > "$STAGE/lib/systemd/system/nesbundler-cleanup.timer" << 'UNIT'
[Unit]
Description=nes-bundler cleanup timer

[Timer]
# Run 10 min after boot, then every 15 min. Persistent=true catches up if
# the host was offline when a fire would have been due.
OnBootSec=10min
OnUnitActiveSec=15min
Persistent=true
Unit=nesbundler-cleanup.service

[Install]
WantedBy=timers.target
UNIT

# --- env conffile -----------------------------------------------------------

install -d "$STAGE/etc/nesbundler"
cat > "$STAGE/etc/nesbundler/default" << 'ENVF'
# Bind address. Default 127.0.0.1 assumes a reverse proxy (e.g. nginx) on the
# same host fronting TLS, rate limits, and large-upload buffering. Set to
# 0.0.0.0 only if you really want uvicorn directly exposed to the network.
BUNDLER_HOST=127.0.0.1
BUNDLER_PORT=8080
# REQUIRED — shared secret the client must POST as a `token` form field on
# /bundle. The service refuses to start with an empty BUNDLER_TOKEN.
# Generate one with: openssl rand -hex 32
BUNDLER_TOKEN=
BUNDLER_MAX_CONCURRENT=1

BUNDLER_JOBS_DIR=/var/lib/nesbundler/jobs
BUNDLER_SOURCE_DIR=/opt/nesbundler
BUNDLER_BUILD_SCRIPT=/opt/nesbundler/bundler/build.sh

# Retention windows for the periodic janitor (nesbundler-cleanup.timer).
# bundle.tar.gz is purged after BUNDLE_TTL; full job dir after JOB_TTL. The
# bundle TTL must be <= the job TTL; the janitor logs a WARNING line into
# build.log before either purge so the audit trail survives.
BUNDLER_BUNDLE_TTL_SECONDS=3600
BUNDLER_JOB_TTL_SECONDS=604800

CARGO_HOME=/var/lib/nesbundler/cargo
CARGO_TARGET_DIR=/var/lib/nesbundler/target

# Per-job cargo target dir. Default 0 = share /var/lib/nesbundler/target across
# jobs (maximises cache hits — recommended for BUNDLER_MAX_CONCURRENT=1, gives
# you "first build cold, next build incremental"). Set to 1 only when you
# want true parallel compiles with concurrency > 1 on a beefy host: each job
# then pays a full cold-rebuild cost (~5 GB on disk, ~20 min wall time) and
# the artifacts live under $JOB_DIR/target, purged with the job dir itself.
BUNDLER_PER_JOB_TARGET_DIR=0

CC_x86_64_pc_windows_gnu=x86_64-w64-mingw32-gcc
CXX_x86_64_pc_windows_gnu=x86_64-w64-mingw32-g++
AR_x86_64_pc_windows_gnu=x86_64-w64-mingw32-ar
CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=x86_64-w64-mingw32-gcc

PATH=/var/lib/nesbundler/.cargo/bin:/opt/nesbundler/vendor/bin:/opt/nesbundler/vendor/zig:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENVF
chmod 0640 "$STAGE/etc/nesbundler/default"

# --- maintainer scripts -----------------------------------------------------

cat > "$SCRIPTS/preinst" << 'PREINST'
#!/bin/sh
set -e
if ! getent passwd bundler >/dev/null; then
    useradd --system --create-home --home-dir /var/lib/nesbundler \
            --shell /usr/sbin/nologin bundler
fi
PREINST

cat > "$SCRIPTS/postinst" << 'POSTINST'
#!/bin/sh
set -e

install -d -o bundler -g bundler -m 0755 \
    /var/lib/nesbundler/jobs \
    /var/lib/nesbundler/cargo \
    /var/lib/nesbundler/target

install -d -o bundler -g bundler -m 0755 /opt/nesbundler/config
chown -R bundler:bundler /opt/nesbundler

chown root:bundler /etc/nesbundler/default
chmod 0640 /etc/nesbundler/default

systemctl daemon-reload || true

# Janitor: enable + start unconditionally. The timer is cheap (oneshot every
# 15 min) and idempotent — safe on fresh installs and upgrades alike.
systemctl enable --now nesbundler-cleanup.timer || true

if [ ! -x /var/lib/nesbundler/.cargo/bin/cargo ]; then
    cat <<MSG
nes-bundler installed.

One-time setup — install the Rust toolchain as the bundler user:
    sudo -u bundler -H bash -c '
      curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal
      . \$HOME/.cargo/env
      rustup target add x86_64-pc-windows-gnu
    '

Then enable + start the service:
    systemctl enable --now nesbundler
MSG
else
    systemctl try-restart nesbundler || true
fi
POSTINST

cat > "$SCRIPTS/prerm" << 'PRERM'
#!/bin/sh
set -e
if [ -d /run/systemd/system ]; then
    systemctl stop nesbundler-cleanup.timer 2>/dev/null || true
    systemctl disable nesbundler-cleanup.timer 2>/dev/null || true
    systemctl stop nesbundler 2>/dev/null || true
    systemctl disable nesbundler 2>/dev/null || true
fi
PRERM

cat > "$SCRIPTS/postrm" << 'POSTRM'
#!/bin/sh
set -e

# Conventional Debian semantics:
#   - `dpkg -r` (remove) keeps /var/lib/nesbundler so a reinstall reuses the
#     cargo registry/target caches (30+ minutes of compile time).
#   - `dpkg -P` (purge) is the explicit "I want this gone" request — wipe
#     all runtime state and remove the bundler system user/group.
case "$1" in
    purge)
        rm -rf /var/lib/nesbundler
        if getent passwd bundler >/dev/null 2>&1; then
            deluser --system --quiet bundler 2>/dev/null \
                || userdel bundler 2>/dev/null || true
        fi
        if getent group bundler >/dev/null 2>&1; then
            delgroup --system --quiet bundler 2>/dev/null \
                || groupdel bundler 2>/dev/null || true
        fi
        ;;
esac

systemctl daemon-reload 2>/dev/null || true
POSTRM

chmod 0755 "$SCRIPTS"/preinst "$SCRIPTS"/postinst \
           "$SCRIPTS"/prerm "$SCRIPTS"/postrm

# --- Build the .deb ---------------------------------------------------------
# Runtime deps only: SDL3 is embedded; X11/Wayland/ALSA/udev -dev packages
# are *not* needed because SDL3 dlopens those at runtime on the *user's*
# machine, not on the bundler service host.

echo ">>> Building .deb..."
fpm \
    --force \
    -s dir \
    -t deb \
    -n "__PKG_NAME__" \
    -v "__VERSION__" \
    --iteration "__PKG_REVISION__" \
    --architecture "__ARCH__" \
    --maintainer "__MAINTAINER__" \
    --description "__DESCRIPTION__" \
    --url "https://github.com/tedsteen/nes-bundler" \
    --license "see /opt/nesbundler/LICENSE" \
    --deb-priority optional \
    --depends "build-essential" \
    --depends "pkg-config" \
    --depends "ca-certificates" \
    --depends "curl" \
    --depends "p7zip-full" \
    --depends "mingw-w64" \
    --depends "python3" \
    --depends "python3-fastapi" \
    --depends "python3-uvicorn" \
    --depends "python3-python-multipart" \
    --depends "python3-dotenv" \
    --depends "python3-yaml" \
    --config-files /etc/nesbundler/default \
    --before-install "$SCRIPTS/preinst" \
    --after-install  "$SCRIPTS/postinst" \
    --before-remove  "$SCRIPTS/prerm" \
    --after-remove   "$SCRIPTS/postrm" \
    --deb-no-default-config-files \
    --package "/output/__DEB_FILE__" \
    -C "$STAGE" \
    .

echo ">>> Package built: /output/__DEB_FILE__"
BUILDEOF

# Substitute build-time values into the chroot script.
sed -i \
    -e "s|__PKG_NAME__|${PKG_NAME}|g" \
    -e "s|__VERSION__|${VERSION}|g" \
    -e "s|__PKG_REVISION__|${PKG_REVISION}|g" \
    -e "s|__ARCH__|${ARCH}|g" \
    -e "s|__MAINTAINER__|${MAINTAINER}|g" \
    -e "s|__DESCRIPTION__|${DESCRIPTION}|g" \
    -e "s|__DEB_FILE__|${DEB_FILE}|g" \
    -e "s|__SDL_VERSION__|${SDL_VERSION}|g" \
    "${CHROOT_DIR}/build.sh"

chmod +x "${CHROOT_DIR}/build.sh"

echo ">>> Entering chroot..."
chroot "${CHROOT_DIR}" /build.sh

umount "${CHROOT_DIR}/output" 2>/dev/null || true
umount "${CHROOT_DIR}/source" 2>/dev/null || true

DEB_SIZE=$(du -h "${DIST_DIR}/${DEB_FILE}" 2>/dev/null | cut -f1 || echo "?")

echo ""
echo "Package: ${DIST_DIR}/${DEB_FILE} (${DEB_SIZE})"
echo ""
echo "Install on the target Debian 13 host:"
echo "  sudo dpkg -i ${DEB_FILE}"
echo "  sudo apt-get install -f"
