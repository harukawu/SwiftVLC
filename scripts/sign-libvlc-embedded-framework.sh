#!/usr/bin/env bash
#
# sign-libvlc-embedded-framework.sh — Sign libVLC nested code in an app build.
#
# Add this to an iOS app target Run Script phase after SwiftPM embeds package
# frameworks. Xcode re-signs libvlc.framework itself, but it does not re-sign
# the loose libvlccore.dylib and VLC plugin dylibs inside that framework. Physical
# iOS devices reject those ad-hoc signatures at dyld load time, so the nested
# code must be signed with the consuming app's identity.
#
# Usage:
#   ./scripts/sign-libvlc-embedded-framework.sh
#   ./scripts/sign-libvlc-embedded-framework.sh path/to/libvlc.framework
#
set -euo pipefail

fail() {
  echo "error: $*" >&2
  exit 1
}

info() {
  echo "[SwiftVLC] $*"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "required tool not found: $1"
}

require_tool cmp
require_tool codesign
require_tool find
require_tool grep
require_tool lipo
require_tool plutil

if [[ "${1:-}" != "" ]]; then
  FRAMEWORK_PATH="$1"
else
  [[ -n "${TARGET_BUILD_DIR:-}" ]] || fail "TARGET_BUILD_DIR is unset; pass libvlc.framework path explicitly"
  [[ -n "${FRAMEWORKS_FOLDER_PATH:-}" ]] || fail "FRAMEWORKS_FOLDER_PATH is unset; pass libvlc.framework path explicitly"
  FRAMEWORK_PATH="${TARGET_BUILD_DIR%/}/${FRAMEWORKS_FOLDER_PATH%/}/libvlc.framework"
fi

[[ -d "$FRAMEWORK_PATH" ]] || fail "libvlc.framework not found at $FRAMEWORK_PATH"

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "NO" || "${PLATFORM_NAME:-}" == *simulator* ]]; then
    IDENTITY="-"
  else
    fail "EXPANDED_CODE_SIGN_IDENTITY is unset for a signed device build"
  fi
fi

ROOT_PLIST="$FRAMEWORK_PATH/Info.plist"
RESOURCES_PLIST="$FRAMEWORK_PATH/Resources/Info.plist"
MAIN_BINARY="$FRAMEWORK_PATH/libvlc"

[[ -f "$ROOT_PLIST" ]] || fail "missing framework Info.plist: $ROOT_PLIST"
[[ -f "$MAIN_BINARY" ]] || fail "missing libvlc framework binary: $MAIN_BINARY"

BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw -o - "$ROOT_PLIST" 2>/dev/null) \
  || fail "cannot read CFBundleIdentifier from $ROOT_PLIST"

if [[ -d "$FRAMEWORK_PATH/Resources" ]]; then
  cp "$ROOT_PLIST" "$RESOURCES_PLIST"
  cmp -s "$ROOT_PLIST" "$RESOURCES_PLIST" \
    || fail "$RESOURCES_PLIST does not match $ROOT_PLIST"
fi

codesign_quietly() {
  local log
  log=$(mktemp)

  if ! codesign --force --sign "$IDENTITY" --timestamp=none "$@" 2>"$log"; then
    cat "$log" >&2
    rm -f "$log"
    return 1
  fi

  grep -v 'replacing existing signature' "$log" >&2 || true
  rm -f "$log"
}

signed_nested=0

while IFS= read -r candidate; do
  [[ "$candidate" == "$MAIN_BINARY" ]] && continue

  if lipo -info "$candidate" >/dev/null 2>&1; then
    codesign_quietly "$candidate"
    signed_nested=$((signed_nested + 1))
  fi
done < <(find "$FRAMEWORK_PATH" -type f -print)

codesign_quietly --identifier "$BUNDLE_ID" --preserve-metadata=entitlements,flags --generate-entitlement-der "$FRAMEWORK_PATH"

if ! codesign --verify --deep --strict "$FRAMEWORK_PATH" >/dev/null 2>&1; then
  codesign --verify --deep --strict --verbose=2 "$FRAMEWORK_PATH" >&2 || true
  fail "libvlc.framework code signature verification failed"
fi

signing_details=$(codesign -dv --verbose=4 "$FRAMEWORK_PATH" 2>&1)
if ! grep -q "^Identifier=${BUNDLE_ID}$" <<<"$signing_details"; then
  echo "$signing_details" >&2
  fail "libvlc.framework signing identifier does not match CFBundleIdentifier"
fi
if ! grep -q '^Info.plist entries=' <<<"$signing_details"; then
  echo "$signing_details" >&2
  fail "libvlc.framework code signature does not bind Info.plist entries"
fi

info "signed libvlc.framework and ${signed_nested} nested Mach-O files with identity ${IDENTITY}"
