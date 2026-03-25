#!/bin/bash
set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 <target> [options]

Targets:
  desktop          Build desktop release
  desktop --pgo    Build desktop with Profile-Guided Optimization
  web              Build WASM target (output in dist/web/)
  android [arch]   Build Android APK (default arch: arm64)
  all              Build all targets

Options:
  --features <f>   Extra cargo features (e.g. --features netplay)
  -h, --help       Show this help
EOF
    exit 0
}

FEATURES=""

ensure_trunk() {
    if ! command -v trunk &>/dev/null; then
        echo "Installing Trunk..."
        cargo install --locked trunk
    fi
}

ensure_xbuild() {
    if ! command -v x &>/dev/null; then
        echo "Installing xbuild..."
        cargo install --locked xbuild
    fi
}

build_desktop() {
    local feature_flag=""
    [[ -n "$FEATURES" ]] && feature_flag="--features $FEATURES"
    echo "==> Building desktop (release)..."
    cargo build --release $feature_flag
    echo "Done! Binary in target/release/"
}

build_desktop_pgo() {
    local profile_path=/tmp/pgo-data
    rm -rf "$profile_path"
    mkdir "$profile_path"

    echo "==> Building desktop with PGO (instrumented)..."
    RUSTFLAGS="-Cprofile-generate=$profile_path -C llvm-args=-vp-counters-per-site=7" cargo build --release

    echo "Run the application, exercise it, then close it."
    ./target/release/nes-bundler &
    local pid=$!
    echo "Waiting for PID $pid to finish..."
    wait "$pid"

    echo "Merging profile data..."
    llvm-profdata merge -o "${profile_path}/merged.profdata" "$profile_path"

    echo "Building with profile data..."
    RUSTFLAGS="-Cprofile-use=${profile_path}/merged.profdata" cargo build --release
    echo "Done! Optimized binary in target/release/"
}

build_web() {
    rustup target add wasm32-unknown-unknown 2>/dev/null || true
    ensure_trunk

    echo "==> Building WASM target..."
    trunk build --release --dist dist/web --public-url ./
    echo "Done! Output in dist/web/"
}

build_android() {
    local arch="${1:-arm64}"
    rustup target add aarch64-linux-android 2>/dev/null || true
    ensure_xbuild

    if [ -z "${ANDROID_NDK_ROOT:-}" ]; then
        echo "Warning: ANDROID_NDK_ROOT is not set."
        echo "Make sure the Android NDK is installed and ANDROID_NDK_ROOT points to it."
    fi

    echo "==> Building Android APK (arch: $arch)..."
    x build --release --platform android --arch "$arch"
    echo "Done! APK in target/x/release/android/"
}

# ── Parse arguments ──────────────────────────────────────────────────────────

[[ $# -eq 0 ]] && usage

TARGET=""
PGO=false
ANDROID_ARCH="arm64"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage ;;
        --features) FEATURES="$2"; shift 2 ;;
        --pgo) PGO=true; shift ;;
        desktop|web|android|all) TARGET="$1"; shift ;;
        *)
            if [[ "$TARGET" == "android" ]]; then
                ANDROID_ARCH="$1"; shift
            else
                echo "Unknown argument: $1"; usage
            fi
            ;;
    esac
done

[[ -z "$TARGET" ]] && { echo "Error: no target specified."; usage; }

case "$TARGET" in
    desktop)
        if $PGO; then build_desktop_pgo; else build_desktop; fi
        ;;
    web)
        build_web
        ;;
    android)
        build_android "$ANDROID_ARCH"
        ;;
    all)
        build_desktop
        build_web
        build_android "$ANDROID_ARCH"
        ;;
esac
