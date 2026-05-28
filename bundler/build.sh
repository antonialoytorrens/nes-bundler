#!/bin/bash
set -euo pipefail

JOB_DIR="$1"
SRC_DIR="${BUNDLER_SOURCE_DIR:-/src}"

# Cargo viu al home del usuari del servei (rustup install), no a /usr/local.
# Si el procés pare no ha injectat el seu bin al PATH (p.ex. SSH manual,
# systemd unit sense EnvironmentFile), prova de carregar-ho aquí.
if ! command -v cargo >/dev/null 2>&1; then
    for candidate in "${CARGO_HOME:-}/env" "${HOME:-}/.cargo/env"; do
        if [[ -n "$candidate" && -f "$candidate" ]]; then
            # shellcheck disable=SC1090
            . "$candidate"
            break
        fi
    done
fi

# SDL3 is pre-built (static .a + sdl3.pc) and shipped under vendor/sdl3/ per
# target. pkg-config picks the right one via PKG_CONFIG_PATH_<triple>.
export PKG_CONFIG_ALLOW_CROSS=1
export PKG_CONFIG_PATH_x86_64_unknown_linux_gnu="${SRC_DIR}/vendor/sdl3/linux/lib/pkgconfig"
export PKG_CONFIG_PATH_x86_64_pc_windows_gnu="${SRC_DIR}/vendor/sdl3/mingw/lib/pkgconfig"

ts() { date -u +%FT%TZ; }
log() { echo "[$(ts)] $*"; }

cd "$JOB_DIR"

log "Unpacking config..."
mkdir -p user_config
7z -y x config.zip -ouser_config > /dev/null

if [[ ! -f user_config/config.yaml ]]; then
    log "ERROR: config.zip must contain 'config.yaml' at its root."
    log "       Zip the *contents* of nes-bundler/config/, not the directory itself."
    log "       Top-level entries found in the archive:"
    (cd user_config && ls -A1) | sed 's/^/         /'
    exit 1
fi

log "Reading bundle metadata..."
# config.yaml uses serde-emitted custom tags (!Keyboard, etc). SafeLoader
# rejects them, so subclass it to treat unknown !Tags as their underlying
# scalar/seq/map. NUL-delimited to survive names with spaces.
mapfile -d '' -t META < <(python3 - user_config/config.yaml <<'PY'
import sys, yaml
class IgnoreTags(yaml.SafeLoader): pass
def _ignore(loader, tag_suffix, node):
    if isinstance(node, yaml.ScalarNode):   return loader.construct_scalar(node)
    if isinstance(node, yaml.SequenceNode): return loader.construct_sequence(node)
    return loader.construct_mapping(node)
IgnoreTags.add_multi_constructor("!", _ignore)
with open(sys.argv[1]) as f:
    data = yaml.load(f, Loader=IgnoreTags) or {}
sys.stdout.write(f"{data['name']}\0{data.get('version') or 'dev'}\0")
PY
)
BUNDLE_NAME="${META[0]}"
BUNDLE_VERSION="${META[1]}"
BUNDLE_SLUG="${BUNDLE_NAME}_${BUNDLE_VERSION}"
log "Bundle: $BUNDLE_NAME $BUNDLE_VERSION"

# server.py reads this for the /download Content-Disposition filename so the
# user gets `${BUNDLE_SLUG}.tar.gz` instead of the opaque job_id.
echo -n "$BUNDLE_SLUG" > "$JOB_DIR/bundle.name"

# Per-job working source tree. We hardlink-copy $SRC_DIR into the job dir and
# point cargo at the copy, then swap in this job's config. Rationale:
#   - Isolates the config swap from any other build (no shared mutable state
#     in /opt), so concurrent jobs are safe even if BUNDLER_MAX_CONCURRENT > 1.
#   - $SRC_DIR stays purely read-only at runtime — no ProtectSystem games.
#   - Cargo only *reads* source files (writes go to CARGO_TARGET_DIR), so
#     hardlinks are safe. Fallback to a full `cp -a` if $JOB_DIR and $SRC_DIR
#     live on different filesystems.
JOB_SRC="$JOB_DIR/src"
mkdir -p "$JOB_SRC"
log "Materializing per-job source tree at $JOB_SRC ..."
cp -al "$SRC_DIR"/. "$JOB_SRC"/ 2>/dev/null || cp -a "$SRC_DIR"/. "$JOB_SRC"/

# Substitute the user's config for the upstream demo config.
rm -rf "$JOB_SRC/config"
cp -a user_config "$JOB_SRC/config"

cd "$JOB_SRC"

ARTIFACTS_DIR="$JOB_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

# CARGO_TARGET_DIR strategy. Default (BUNDLER_PER_JOB_TARGET_DIR=0): inherit
# the shared /var/lib/nesbundler/target from /etc/nesbundler/default — maximises
# cache hit, ideal for BUNDLER_MAX_CONCURRENT=1. Opt-in (=1): per-job target
# dir, enables true parallel compile when concurrency > 1, at the cost of a
# cold rebuild on every job (~5 GB + ~20 min per job).
if [[ "${BUNDLER_PER_JOB_TARGET_DIR:-0}" == "1" ]]; then
    export CARGO_TARGET_DIR="$JOB_DIR/target"
    log "Per-job CARGO_TARGET_DIR=$CARGO_TARGET_DIR (cold rebuild expected)"
fi

# Linux: zigbuild pins the glibc target so the produced binary runs on any
# distro with glibc >= the target (CentOS 7 era and newer). The per-target
# output dir under CARGO_TARGET_DIR drops the glibc suffix — files land at
# x86_64-unknown-linux-gnu/release/ just like a plain `cargo build`.
log "cargo zigbuild --target x86_64-unknown-linux-gnu.2.17 ..."
cargo zigbuild --locked --release --target x86_64-unknown-linux-gnu.2.17

# Rename the binary inside the tarball to match the bundle so users get a
# meaningful filename after extracting (not a generic 'nes-bundler').
LINUX_STAGE="$(mktemp -d)"
trap 'rm -rf "$LINUX_STAGE"' EXIT
cp "${CARGO_TARGET_DIR}/x86_64-unknown-linux-gnu/release/nes-bundler" \
   "${LINUX_STAGE}/${BUNDLE_NAME}"
tar -C "$LINUX_STAGE" -czf \
    "${ARTIFACTS_DIR}/${BUNDLE_SLUG}_Linux.tar.gz" "${BUNDLE_NAME}"

# Windows cross via mingw: ship the raw .exe (no glibc concerns).
log "cargo build --target x86_64-pc-windows-gnu ..."
cargo build --locked --release --target x86_64-pc-windows-gnu
cp "${CARGO_TARGET_DIR}/x86_64-pc-windows-gnu/release/nes-bundler.exe" \
   "${ARTIFACTS_DIR}/${BUNDLE_SLUG}_Windows.exe"

log "Packing bundle..."
cd "$JOB_DIR"
tar -czf bundle.tar.gz -C artifacts .

log "Done"
