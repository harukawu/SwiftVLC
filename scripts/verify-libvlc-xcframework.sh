#!/usr/bin/env bash
#
# verify-libvlc-xcframework.sh — Validate the LGPL-oriented dynamic iOS
# libVLC xcframework shape expected by this fork.
#
# Usage:
#   ./scripts/verify-libvlc-xcframework.sh [Vendor/libvlc.xcframework]
#
set -euo pipefail

XCFW_PATH="${1:-Vendor/libvlc.xcframework}"

fail() {
  echo "Error: $*" >&2
  exit 1
}

info() {
  echo "[verify] $*"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "required tool not found: $1"
}

require_tool file
require_tool find
require_tool grep
require_tool lipo
require_tool otool

[[ -d "$XCFW_PATH" ]] || fail "$XCFW_PATH does not exist"

archive_hit=$(find "$XCFW_PATH" \( -name '*.a' -o -name '*.la' \) -print -quit)
if [[ -n "$archive_hit" ]]; then
  fail "static or libtool archive found in xcframework: $archive_hit"
fi

module_hit=$(find "$XCFW_PATH" \( -name 'module.modulemap' -o -name 'CLibVLC.h' \) -print -quit)
if [[ -n "$module_hit" ]]; then
  fail "binary framework headers contain CLibVLC module metadata: $module_hit"
fi

EXPECTED_SLICES=(
  "ios-arm64:arm64"
  "ios-arm64_x86_64-simulator:arm64 x86_64"
)

for spec in "${EXPECTED_SLICES[@]}"; do
  slice="${spec%%:*}"
  archs="${spec#*:}"
  framework="$XCFW_PATH/$slice/libvlc.framework"
  binary="$framework/libvlc"

  [[ -d "$framework" ]] || fail "missing framework slice: $slice"
  [[ -f "$binary" ]] || fail "missing libvlc binary for slice: $slice"

  if ! file "$binary" | grep -q "dynamically linked shared library"; then
    file "$binary" >&2
    fail "libvlc binary is not a dynamic library for slice: $slice"
  fi

  for arch in $archs; do
    lipo "$binary" -verify_arch "$arch" >/dev/null 2>&1 \
      || fail "$binary is missing architecture: $arch"
  done

  install_name=$(otool -D "$binary" | tail -n 1)
  [[ "$install_name" == "@rpath/libvlc.framework/libvlc" ]] \
    || fail "$binary has unexpected install name: $install_name"

  [[ -d "$framework/Headers/vlc" ]] || fail "missing VLC headers in slice: $slice"
  [[ -d "$framework/plugins" ]] || fail "missing dynamic VLC plugins in slice: $slice"

  info "$slice: $(lipo -info "$binary")"
done

while IFS= read -r candidate; do
  if ! lipo -info "$candidate" >/dev/null 2>&1; then
    continue
  fi

  if otool -L "$candidate" | grep -E '(/scripts/\.build-libvlc/|/build-iphoneos-|/build-iphonesimulator-|/vlc-iphoneos|/vlc-iphonesimulator)' >/dev/null; then
    otool -L "$candidate" >&2
    fail "Mach-O load commands reference build output paths: $candidate"
  fi

  name="$(basename "$candidate")"
  case "$name" in
    libvlc)
      continue
      ;;
    *.dylib)
      install_name=$(otool -D "$candidate" | tail -n 1)
      expected="@loader_path/$name"
      [[ "$install_name" == "$expected" ]] \
        || fail "$candidate has unexpected install name: $install_name"
      ;;
  esac
done < <(find "$XCFW_PATH" -type f -print)

info "dynamic iOS libVLC xcframework verification passed"
