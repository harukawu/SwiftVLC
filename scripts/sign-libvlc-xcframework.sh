#!/usr/bin/env bash
#
# sign-libvlc-xcframework.sh — Ad-hoc sign libVLC framework slices.
#
# Xcode re-signs the top-level libvlc.framework when embedding it into an app,
# but it does not sign loose nested dylibs/plugins first. Those nested Mach-O
# files must carry at least an ad-hoc signature or the app's CodeSign step fails
# with "code object is not signed at all" for libvlccore.dylib or a plugin.
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

[[ -d "$XCFW_PATH" ]] || fail "$XCFW_PATH does not exist"

codesign_quietly() {
  local log
  log=$(mktemp)

  if ! codesign --force --sign - --timestamp=none "$1" 2>"$log"; then
    cat "$log" >&2
    rm -f "$log"
    return 1
  fi

  grep -v 'replacing existing signature' "$log" >&2 || true
  rm -f "$log"
}

signed_frameworks=0

while IFS= read -r framework; do
  signed_frameworks=$((signed_frameworks + 1))
  main_binary="$framework/libvlc"
  [[ -f "$main_binary" ]] || fail "missing libvlc binary in framework: $framework"

  while IFS= read -r candidate; do
    [[ "$candidate" == "$main_binary" ]] && continue

    if lipo -info "$candidate" >/dev/null 2>&1; then
      codesign_quietly "$candidate"
    fi
  done < <(find "$framework" -type f -print)

  codesign_quietly "$framework"
done < <(find "$XCFW_PATH" -path '*/libvlc.framework' -type d -print)

[[ "$signed_frameworks" -gt 0 ]] || fail "no libvlc.framework slices found in $XCFW_PATH"
