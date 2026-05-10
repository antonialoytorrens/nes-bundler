#!/bin/bash
set -euo pipefail

JOB_DIR="$1"
SRC_DIR="${BUNDLER_SOURCE_DIR:-/src}"

ts() { date -u +%FT%TZ; }
log() { echo "[$(ts)] $*"; }

cd "$JOB_DIR"

log "Unpacking config..."
mkdir -p user_config
7z -y x config.zip -ouser_config > /dev/null

log "Reading bundle metadata..."
BUNDLE_NAME=$(python3 -c 'import yaml,sys; print(yaml.safe_load(open(sys.argv[1]))["name"])' user_config/config.yaml)
BUNDLE_VERSION=$(python3 -c 'import yaml,sys; v=yaml.safe_load(open(sys.argv[1])).get("version"); print(v if v else "dev")' user_config/config.yaml)
log "Bundle: $BUNDLE_NAME $BUNDLE_VERSION"

# Builds are serialized in the server (asyncio.Semaphore), so swapping the
# config dir on the shared source tree is safe.
rm -rf "$SRC_DIR/config"
cp -r user_config "$SRC_DIR/config"

cd "$SRC_DIR"

ARTIFACTS_DIR="$JOB_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

# Linux native: tar up the binary so permissions survive
log "cargo build --target x86_64-unknown-linux-gnu ..."
cargo build --locked --release --target x86_64-unknown-linux-gnu
tar -C "${CARGO_TARGET_DIR}/x86_64-unknown-linux-gnu/release" -czf \
    "${ARTIFACTS_DIR}/${BUNDLE_NAME} ${BUNDLE_VERSION} Linux.tar.gz" nes-bundler

# Windows cross via mingw: ship the raw .exe
log "cargo build --target x86_64-pc-windows-gnu ..."
cargo build --locked --release --target x86_64-pc-windows-gnu
cp "${CARGO_TARGET_DIR}/x86_64-pc-windows-gnu/release/nes-bundler.exe" \
   "${ARTIFACTS_DIR}/${BUNDLE_NAME} ${BUNDLE_VERSION} Windows.exe"

log "Packing bundle..."
cd "$JOB_DIR"
tar -czf bundle.tar.gz -C artifacts .

log "Done"
