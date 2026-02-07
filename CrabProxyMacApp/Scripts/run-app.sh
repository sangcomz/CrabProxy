#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

"$SCRIPT_DIR/build-rust.sh" debug
cd "$APP_DIR"
swift run CrabProxyMacApp
