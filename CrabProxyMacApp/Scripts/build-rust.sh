#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$APP_DIR/.." && pwd)"
RUST_DIR="$ROOT_DIR/crab-mitm"

PROFILE="${1:-debug}"
if [[ "${CONFIGURATION:-}" == "Release" ]]; then
  PROFILE="release"
fi

# Xcode GUI launches scripts with a restricted PATH on some setups.
if ! command -v cargo >/dev/null 2>&1; then
  if [[ -f "$HOME/.cargo/env" ]]; then
    # shellcheck disable=SC1090
    source "$HOME/.cargo/env"
  fi
fi
if ! command -v cargo >/dev/null 2>&1; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi
if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not found. Install Rust toolchain or add cargo to PATH." >&2
  exit 127
fi

if [[ ! -f "$RUST_DIR/Cargo.toml" ]]; then
  echo "error: rust project not found at $RUST_DIR" >&2
  exit 1
fi

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
mkdir -p "$RUST_DIR/target/debug" "$RUST_DIR/target/release"
mkdir -p "$APP_DIR/Sources/CCrabMitm/include"

if [[ "$PROFILE" == "release" ]]; then
  cargo build --manifest-path "$RUST_DIR/Cargo.toml" --lib --release
else
  cargo build --manifest-path "$RUST_DIR/Cargo.toml" --lib
fi

cp "$RUST_DIR/include/crab_mitm.h" "$APP_DIR/Sources/CCrabMitm/include/crab_mitm.h"
