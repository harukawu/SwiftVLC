#!/usr/bin/env bash
#
# sign-libvlc-xcframework.sh — Ad-hoc sign libVLC framework slices.
#
# Xcode re-signs the top-level libvlc.framework when embedding it into an app,
# but it does not sign loose nested dylibs/plugins first. Those nested Mach-O
# files must carry at least an ad-hoc signature or the app's CodeSign step fails
# with "code object is not signed at all" for libvlccore.dylib or a plugin.
# Because VLC resources create a top-level Resources directory, the framework
# must also carry Resources/Info.plist and a signing identifier matching its
# CFBundleIdentifier or physical iOS device installation rejects the bundle.
#
# Usage:
#   ./scripts/sign-libvlc-xcframework.sh [Vendor/libvlc.xcframework]
#
set -euo pipefail

XCFW_PATH="${1:-Vendor/libvlc.xcframework}"

fail() {
  echo "Error: $*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "required tool not found: $1"
}

require_tool codesign
require_tool find
require_tool lipo
require_tool plutil

[[ -d "$XCFW_PATH" ]] || fail "$XCFW_PATH does not exist"

codesign_quietly() {
  local log
  log=$(mktemp)

  if ! codesign --force --sign - --timestamp=none "$@" 2>"$log"; then
    cat "$log" >&2
    rm -f "$log"
    return 1
  fi

  grep -v 'replacing existing signature' "$log" >&2 || true
  rm -f "$log"
}

prepare_framework_plist() {
  local framework="$1"
  local root_plist="$framework/Info.plist"
  local resources_dir="$framework/Resources"

  [[ -f "$root_plist" ]] || fail "missing Info.plist in framework: $framework"

  # iOS frameworks normally use a root Info.plist. VLC also ships
  # Resources/share; that top-level Resources directory makes codesign use the
  # deep-framework plist location, so mirror the plist there as well.
  if [[ -d "$resources_dir" ]]; then
    cp "$root_plist" "$resources_dir/Info.plist"
  fi
}

framework_identifier() {
  local framework="$1"
  plutil -extract CFBundleIdentifier raw -o - "$framework/Info.plist" 2>/dev/null \
    || fail "cannot read CFBundleIdentifier from $framework/Info.plist"
}

signed_frameworks=0

while IFS= read -r framework; do
  signed_frameworks=$((signed_frameworks + 1))
  main_binary="$framework/libvlc"
  [[ -f "$main_binary" ]] || fail "missing libvlc binary in framework: $framework"
  prepare_framework_plist "$framework"
  bundle_id=$(framework_identifier "$framework")

  while IFS= read -r candidate; do
    [[ "$candidate" == "$main_binary" ]] && continue

    if lipo -info "$candidate" >/dev/null 2>&1; then
      codesign_quietly "$candidate"
    fi
  done < <(find "$framework" -type f -print)

  codesign_quietly --identifier "$bundle_id" "$framework"
done < <(find "$XCFW_PATH" -path '*/libvlc.framework' -type d -print)

[[ "$signed_frameworks" -gt 0 ]] || fail "no libvlc.framework slices found in $XCFW_PATH"
