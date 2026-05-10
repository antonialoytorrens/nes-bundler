#!/bin/bash
# System packages needed to build + run the nes-bundler bundler service on
# Debian/Ubuntu. Used by both the Dockerfile and native deployments. Safe to
# re-run; apt-get is idempotent.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    exec sudo -E "$0" "$@"
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    pkg-config \
    ca-certificates \
    curl \
    git \
    p7zip-full \
    \
    libx11-dev \
    libxcursor-dev \
    libxi-dev \
    libxrandr-dev \
    libxss-dev \
    libxtst-dev \
    libxkbcommon-dev \
    libwayland-dev \
    libasound2-dev \
    libudev-dev \
    libfontconfig1-dev \
    libssl-dev \
    \
    mingw-w64 \
    mingw-w64-tools \
    \
    python3 \
    python3-fastapi \
    python3-uvicorn \
    python3-multipart \
    python3-yaml
