#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$APP_DIR/.." && pwd)"
RUST_DIR="$ROOT_DIR/crab-mitm"
HELPER_LABEL="com.sangcomz.CrabProxyHelper"

PROFILE="${1:-debug}"
if [[ "${CONFIGURATION:-}" == "Release" ]]; then
  PROFILE="release"
fi

build_helper_resource_binary() {
  local helper_src_dir="$APP_DIR/Sources/CrabProxyHelper"

  # This path is only available when the script is invoked by Xcode.
  if [[ -z "${TARGET_BUILD_DIR:-}" || -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]]; then
    return 0
  fi

  if [[ ! -f "$helper_src_dir/main.swift" || ! -f "$helper_src_dir/HelperProtocol.swift" ]]; then
    echo "warning: helper sources not found, skipping helper binary packaging" >&2
    return 0
  fi

  local resources_dir="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
  local helper_output="$resources_dir/$HELPER_LABEL"
  local sdk_path deployment_target

  sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
  deployment_target="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
  mkdir -p "$resources_dir"

  IFS=' ' read -r -a helper_arches <<<"${ARCHS:-$(uname -m)}"
  local tmp_dir
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/crabproxy-helper.XXXXXX")"
  local arch_bins=()

  for arch in "${helper_arches[@]}"; do
    case "$arch" in
      arm64|x86_64)
        ;;
      arm64e)
        arch="arm64"
        ;;
      *)
        echo "warning: unsupported helper arch '$arch', skipping" >&2
        continue
        ;;
    esac

    local arch_output="$tmp_dir/$arch"
    xcrun swiftc \
      -sdk "$sdk_path" \
      -target "$arch-apple-macos$deployment_target" \
      "$helper_src_dir/HelperProtocol.swift" \
      "$helper_src_dir/main.swift" \
      -o "$arch_output"
    arch_bins+=("$arch_output")
  done

  if [[ ${#arch_bins[@]} -eq 0 ]]; then
    rm -rf "$tmp_dir"
    echo "error: failed to build helper binary for any architecture" >&2
    return 1
  fi

  if [[ ${#arch_bins[@]} -eq 1 ]]; then
    cp "${arch_bins[0]}" "$helper_output"
  else
    /usr/bin/lipo -create "${arch_bins[@]}" -output "$helper_output"
  fi

  chmod 755 "$helper_output"
  echo "Helper binary packaged at: $helper_output"
  /usr/bin/lipo -info "$helper_output" || true
  rm -rf "$tmp_dir"
}

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

# Xcode archive for macOS typically builds both arm64 and x86_64.
# Build Rust staticlib per-arch and merge them as a universal archive.
IFS=' ' read -r -a xcode_arches <<<"${ARCHS:-$(uname -m)}"
rust_targets=()
for arch in "${xcode_arches[@]}"; do
  case "$arch" in
    arm64)
      rust_targets+=("aarch64-apple-darwin")
      ;;
    x86_64)
      rust_targets+=("x86_64-apple-darwin")
      ;;
    *)
      echo "warning: unsupported Xcode ARCH '$arch', skipping for Rust build" >&2
      ;;
  esac
done

if [[ ${#rust_targets[@]} -eq 0 ]]; then
  echo "error: no supported Rust targets resolved from ARCHS='${ARCHS:-}'" >&2
  exit 1
fi

if command -v rustup >/dev/null 2>&1; then
  for target in "${rust_targets[@]}"; do
    if ! rustup target list --installed | grep -qx "$target"; then
      rustup target add "$target"
    fi
  done
fi

archives=()
crabd_bins=()
crabctl_bins=()
for target in "${rust_targets[@]}"; do
  build_cmd=(cargo build --manifest-path "$RUST_DIR/Cargo.toml" --lib --bin crabd --bin crabctl --target "$target")
  if [[ "$PROFILE" == "release" ]]; then
    build_cmd+=(--release)
  fi
  "${build_cmd[@]}"
  archives+=("$RUST_DIR/target/$target/$PROFILE/libcrab_mitm.a")
  crabd_bins+=("$RUST_DIR/target/$target/$PROFILE/crabd")
  crabctl_bins+=("$RUST_DIR/target/$target/$PROFILE/crabctl")
done

OUTPUT_LIB="$RUST_DIR/target/$PROFILE/libcrab_mitm.a"
if [[ ${#archives[@]} -eq 1 ]]; then
  cp "${archives[0]}" "$OUTPUT_LIB"
else
  /usr/bin/lipo -create "${archives[@]}" -output "$OUTPUT_LIB"
fi

echo "Rust staticlib prepared at: $OUTPUT_LIB"
/usr/bin/lipo -info "$OUTPUT_LIB" || true

cp "$RUST_DIR/include/crab_mitm.h" "$APP_DIR/Sources/CCrabMitm/include/crab_mitm.h"

OUTPUT_CRABD="$RUST_DIR/target/$PROFILE/crabd"
OUTPUT_CRABCTL="$RUST_DIR/target/$PROFILE/crabctl"
if [[ ${#crabd_bins[@]} -eq 1 ]]; then
  cp "${crabd_bins[0]}" "$OUTPUT_CRABD"
  cp "${crabctl_bins[0]}" "$OUTPUT_CRABCTL"
else
  /usr/bin/lipo -create "${crabd_bins[@]}" -output "$OUTPUT_CRABD"
  /usr/bin/lipo -create "${crabctl_bins[@]}" -output "$OUTPUT_CRABCTL"
fi

echo "Rust daemon binary prepared at: $OUTPUT_CRABD"
/usr/bin/lipo -info "$OUTPUT_CRABD" || true
echo "Rust control binary prepared at: $OUTPUT_CRABCTL"
/usr/bin/lipo -info "$OUTPUT_CRABCTL" || true

if [[ -n "${TARGET_BUILD_DIR:-}" && -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]]; then
  resources_dir="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
  mkdir -p "$resources_dir"

  cp "$OUTPUT_CRABD" "$resources_dir/crabd"
  cp "$OUTPUT_CRABCTL" "$resources_dir/crabctl"
  chmod 755 "$resources_dir/crabd" "$resources_dir/crabctl"

  if command -v codesign >/dev/null 2>&1; then
    /usr/bin/codesign --force --sign - --timestamp=none --identifier "com.sangcomz.CrabProxy.crabd" "$resources_dir/crabd" || true
    /usr/bin/codesign --force --sign - --timestamp=none --identifier "com.sangcomz.crabctl" "$resources_dir/crabctl" || true
  fi

  echo "Packaged Rust binaries at: $resources_dir/crabd, $resources_dir/crabctl"
fi

build_helper_resource_binary
