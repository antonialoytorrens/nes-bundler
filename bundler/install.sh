#!/bin/bash
# System packages needed to build + run the nes-bundler bundler service on
# Debian/Ubuntu. Used by both the Dockerfile and native deployments. Safe to
# re-run; apt-get is idempotent.
#
# SDL3 is shipped pre-built (static .a per target) under
# /opt/nesbundler/vendor/sdl3/, located via pkg-config — that's why the
# X11/Wayland/ALSA/udev -dev packages are no longer in this list.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    exec sudo -E "$0" "$@"
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
    build-essential \
    pkg-config \
    ca-certificates \
    curl \
    p7zip-full \
    \
    mingw-w64 \
    \
    python3 \
    python3-fastapi \
    python3-uvicorn \
    python3-multipart \
    python3-dotenv \
    python3-yaml
