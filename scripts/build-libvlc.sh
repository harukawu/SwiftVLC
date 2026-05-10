#!/bin/bash
# build-libvlc.sh — Compiles libVLC from official VLC source for iOS
# Produces: Vendor/libvlc.xcframework (dynamic iOS frameworks + C headers)
#
# Prerequisites:
#   - Xcode command line tools
#   - Python 3
#   - autoconf, automake, libtool (brew install autoconf automake libtool)
#   - gas-preprocessor (installed automatically by VLC build system)
#
# Usage:
#   ./build-libvlc.sh              # Build for iOS device + simulator
#   ./build-libvlc.sh --ios-only   # iOS device + simulator only
#   ./build-libvlc.sh --clean      # Remove build directory
#   ./build-libvlc.sh --hash=abc   # Pin to a specific VLC commit

set -e

# --- Error trap for better failure reporting ---
trap 'error "Build failed at line $LINENO (exit code $?)"' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${SCRIPT_DIR}/.build-libvlc"
OUTPUT_DIR="${REPO_ROOT}/Vendor"
VLC_REPO="https://code.videolan.org/videolan/vlc.git"
VLC_BRANCH="master"
# Pin to a known-good commit for reproducible builds (same as VLCKit)
# Update this hash when upgrading libVLC
VLC_HASH="c833c4be0"

# Directory containing patches from VLCKit (optional, user must opt in)
PATCHES_DIR=""

BUILD_IOS=yes
BUILD_TVOS=no
BUILD_VISIONOS=no
BUILD_MACOS=no
BUILD_CATALYST=no

# Keep these deployment targets in sync with Package.swift.
SWIFTVLC_MIN_IOS="18.0"
SWIFTVLC_MIN_TVOS="18.0"
SWIFTVLC_MIN_VISIONOS="2.0"
SWIFTVLC_MIN_MACOS="15.0"
SWIFTVLC_MIN_CATALYST="18.0"

BUILD_START_TIME=$(date +%s)

# --- Terminal color support ---
# Guard tput calls for non-terminal contexts (CI runners, piped output)
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1; then
    COLOR_GREEN=$(tput setaf 2)
    COLOR_RED=$(tput setaf 1)
    COLOR_YELLOW=$(tput setaf 3)
    COLOR_RESET=$(tput sgr0)
else
    COLOR_GREEN=""
    COLOR_RED=""
    COLOR_YELLOW=""
    COLOR_RESET=""
fi

elapsed() {
    local now=$(date +%s)
    local secs=$((now - BUILD_START_TIME))
    local mins=$((secs / 60))
    local remaining_secs=$((secs % 60))
    printf "%dm%02ds" "$mins" "$remaining_secs"
}

info() {
    echo "[${COLOR_GREEN}info${COLOR_RESET}] [$(elapsed)] $1"
}

warn() {
    echo "[${COLOR_YELLOW}warn${COLOR_RESET}] [$(elapsed)] $1" >&2
}

error() {
    echo "[${COLOR_RED}error${COLOR_RESET}] [$(elapsed)] $1" >&2
    exit 1
}

detect_core_count() {
    local cores=""

    if cores=$(sysctl -n machdep.cpu.core_count 2>/dev/null) && [ -n "$cores" ]; then
        echo "$cores"
        return 0
    fi

    if command -v nproc >/dev/null 2>&1; then
        if cores=$(nproc 2>/dev/null) && [ -n "$cores" ]; then
            echo "$cores"
            return 0
        fi
    fi

    if cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null) && [ -n "$cores" ]; then
        echo "$cores"
        return 0
    fi

    echo "1"
}

if [ -z "${MAKEFLAGS:-}" ]; then
    MAKEFLAGS="-j$(detect_core_count)"
fi

# --- Prerequisite validation ---
# Maps a missing command to the Homebrew formula that provides it.
# Keep in sync with the `for cmd` loop in check_prerequisites.
brew_formula_for() {
    case "$1" in
        autoconf|automake|libtool|cmake|pkg-config|gettext|nasm|meson|ninja)
            echo "$1" ;;
        autopoint) echo "gettext" ;;
        python3) echo "python@3" ;;
        *) echo "$1" ;;
    esac
}

check_prerequisites() {
    # Xcode itself (not just the Command Line Tools) is required because the
    # final step uses `xcodebuild -create-xcframework`. CLT ships xcode-select
    # but not xcodebuild.
    if ! xcode-select -p >/dev/null 2>&1; then
        echo "${COLOR_RED}Error: Xcode / Command Line Tools not installed.${COLOR_RESET}" >&2
        echo "  Install Xcode from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app" >&2
        exit 1
    fi
    if ! command -v xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
        echo "${COLOR_RED}Error: xcodebuild not available.${COLOR_RESET}" >&2
        echo "  This usually means xcode-select points at Command Line Tools only." >&2
        echo "  Install the full Xcode and run: sudo xcode-select -s /Applications/Xcode.app" >&2
        exit 1
    fi

    # Tools needed on the host. VLC's extras/tools bootstraps its own copies of
    # nasm, meson, ninja, m4, bison, libtool — those don't need to be pre-installed.
    # What we check here is the minimum set required BEFORE extras/tools can run
    # and for autoreconf to succeed (gettext macros via autopoint) and for contribs
    # that use cmake / pkg-config.
    local required=(autoconf automake libtool autopoint pkg-config cmake python3)
    local missing=()

    for cmd in "${required[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo "${COLOR_RED}Error: Missing required tools: ${missing[*]}${COLOR_RESET}" >&2
        echo "" >&2
        echo "  Install with:" >&2
        # Deduplicate formula names (autopoint → gettext, so both map to gettext).
        local formulas=()
        for cmd in "${missing[@]}"; do
            local f
            f=$(brew_formula_for "$cmd")
            local seen=0
            for existing in "${formulas[@]}"; do
                [ "$existing" = "$f" ] && seen=1 && break
            done
            [ "$seen" = 0 ] && formulas+=("$f")
        done
        echo "    brew install ${formulas[*]}" >&2
        echo "" >&2
        echo "  If autopoint is still missing after installing gettext, run:" >&2
        echo "    brew link --force gettext" >&2
        echo "" >&2
        exit 1
    fi
}

# --- Disk space check ---
check_disk_space() {
    local required_gb=40
    local available_kb
    available_kb=$(df -k "$SCRIPT_DIR" | awk 'NR==2 {print $4}')
    local available_gb=$((available_kb / 1024 / 1024))

    if [ "$available_gb" -lt "$required_gb" ]; then
        warn "Low disk space: ${available_gb}GB available, ~${required_gb}GB recommended for a full build."
        warn "The build may fail if disk space runs out."
    fi
}

# --- Parse arguments ---
for arg in "$@"; do
    case $arg in
        --all)
            echo "Error: this fork only rebuilds iOS libVLC slices. Use '$0' or '$0 --ios-only'." >&2
            exit 1
            ;;
        --ios-only)
            BUILD_IOS=yes
            BUILD_TVOS=no
            BUILD_VISIONOS=no
            BUILD_MACOS=no
            BUILD_CATALYST=no
            ;;
        --tvos|--visionos|--macos|--catalyst|--tvos-only|--visionos-only|--macos-only|--catalyst-only)
            echo "Error: this fork only rebuilds iOS libVLC slices; '${arg}' is unsupported." >&2
            exit 1
            ;;
        --clean)
            echo "Removing build directory: ${BUILD_DIR}"
            rm -rf "${BUILD_DIR}"
            echo "Done."
            exit 0
            ;;
        --clean-build)
            echo "Removing build directory: ${BUILD_DIR}"
            rm -rf "${BUILD_DIR}"
            echo "Continuing with fresh build..."
            ;;
        --hash=*)
            VLC_HASH="${arg#--hash=}"
            if [ -z "$VLC_HASH" ]; then
                echo "Error: --hash requires a commit hash value" >&2
                exit 1
            fi
            ;;
        --patches-dir=*)
            PATCHES_DIR="${arg#--patches-dir=}"
            if [ ! -d "$PATCHES_DIR" ]; then
                echo "Error: Patches directory not found: ${PATCHES_DIR}" >&2
                exit 1
            fi
            ;;
        --help)
            cat <<HELPEOF
Usage: $0 [OPTIONS]

Platform selection:
  --ios-only         iOS device + simulator only (default)

Build options:
  --clean            Remove the build directory and exit
  --clean-build      Remove the build directory, then build
  --hash=COMMIT      Pin to a specific VLC commit (default: ${VLC_HASH})
  --patches-dir=DIR  Directory containing .patch files to apply

Other:
  --help             Show this help message

Examples:
  $0                          # Build for iOS (default)
  $0 --ios-only               # Explicit iOS-only build
  $0 --hash=abc123            # Build iOS from a specific commit
  $0 --clean-build            # Fresh iOS build
HELPEOF
            exit 0
            ;;
        *)
            echo "Error: Unknown argument '${arg}'" >&2
            echo "Run '$0 --help' for usage information." >&2
            exit 1
            ;;
    esac
done

# --- Run startup checks ---
check_prerequisites
check_disk_space

# Normalize architecture name for directory naming
# VLC's build.sh accepts "aarch64" but creates "arm64" directories internally
get_actual_arch() {
    if [ "$1" = "aarch64" ]; then
        echo "arm64"
    else
        echo "$1"
    fi
}

# Patch VLC's build system to support Mac Catalyst builds.
# Catalyst uses the macOS SDK with the clang target triple
# arm64-apple-ios{version}-macabi, which VLC doesn't support natively.
# This function modifies build.sh and build.conf in-place (safe because
# the VLC source is reset to a pinned hash on each run).
patch_vlc_for_catalyst() {
    local BUILD_SH="${VLC_SRC}/extras/package/apple/build.sh"
    local BUILD_CONF="${VLC_SRC}/extras/package/apple/build.conf"

    if grep -q "VLC_BUILD_CATALYST" "$BUILD_SH"; then
        info "VLC build.sh already patched for Catalyst"
        return 0
    fi

    info "Patching VLC build system for Mac Catalyst support..."

    python3 - "$BUILD_SH" "$BUILD_CONF" << 'PYEOF'
import sys

build_sh_path = sys.argv[1]
build_conf_path = sys.argv[2]

# --- Patch build.conf: add Catalyst deployment target ---
with open(build_conf_path, 'a') as f:
    f.write('\n# Mac Catalyst deployment target\n')
    f.write('export VLC_DEPLOYMENT_TARGET_CATALYST="18.0"\n')

# --- Patch build.sh ---
with open(build_sh_path, 'r') as f:
    content = f.read()

# 1. Add VLC_BUILD_CATALYST=0 global variable
content = content.replace(
    'VLC_BUILD_EXTRA_CHECKS=0\n',
    'VLC_BUILD_EXTRA_CHECKS=0\n'
    '# Whether building for Mac Catalyst\n'
    'VLC_BUILD_CATALYST=0\n',
    1
)

# 2. Add --catalyst) argument parsing case
content = content.replace(
    '        --enable-extra-checks)\n'
    '            VLC_BUILD_EXTRA_CHECKS=1\n'
    '            ;;',
    '        --enable-extra-checks)\n'
    '            VLC_BUILD_EXTRA_CHECKS=1\n'
    '            ;;\n'
    '        --catalyst)\n'
    '            VLC_BUILD_CATALYST=1\n'
    '            ;;'
)

# 3. Add Catalyst override block after set_build_triplet, before readonly declarations
content = content.replace(
    'set_build_triplet\n'
    '\n'
    '# Set pseudo-triplet',
    'set_build_triplet\n'
    '\n'
    '# Mac Catalyst: override platform settings to use macabi target triple\n'
    'if [ "$VLC_BUILD_CATALYST" -gt "0" ]; then\n'
    '    VLC_HOST_PLATFORM="macCatalyst"\n'
    '    VLC_HOST_OS="ios"\n'
    '    VLC_DEPLOYMENT_TARGET="${VLC_DEPLOYMENT_TARGET_CATALYST:-16.0}"\n'
    '    VLC_DEPLOYMENT_TARGET_CFLAG="--target=${VLC_HOST_ARCH}-apple-ios${VLC_DEPLOYMENT_TARGET}-macabi"\n'
    '    VLC_DEPLOYMENT_TARGET_LDFLAG="${VLC_DEPLOYMENT_TARGET_CFLAG}"\n'
    '    VLC_APPLE_SDK_NAME="maccatalyst${VLC_DEPLOYMENT_TARGET}"\n'
    'fi\n'
    '\n'
    '# Set pseudo-triplet'
)

# 4. Add iOSSupport framework path in set_host_envvars()
#    (unique context: followed by "local bitcode_flag")
content = content.replace(
    '    local clike_flags="$VLC_DEPLOYMENT_TARGET_CFLAG -arch $VLC_HOST_ARCH -isysroot $VLC_APPLE_SDK_PATH $1"\n'
    '    local bitcode_flag=""',
    '    local clike_flags="$VLC_DEPLOYMENT_TARGET_CFLAG -arch $VLC_HOST_ARCH -isysroot $VLC_APPLE_SDK_PATH $1"\n'
    '    if [ "${VLC_BUILD_CATALYST:-0}" -gt "0" ]; then\n'
    '        clike_flags+=" -iframework ${VLC_APPLE_SDK_PATH}/System/iOSSupport/System/Library/Frameworks"\n'
    '    fi\n'
    '    local bitcode_flag=""'
)

# 5. Add iOSSupport framework path in write_config_mak()
#    (unique context: followed by blank line then "local vlc_cppflags")
content = content.replace(
    '    local clike_flags="$VLC_DEPLOYMENT_TARGET_CFLAG -arch $VLC_HOST_ARCH -isysroot $VLC_APPLE_SDK_PATH $1"\n'
    '\n'
    '    local vlc_cppflags',
    '    local clike_flags="$VLC_DEPLOYMENT_TARGET_CFLAG -arch $VLC_HOST_ARCH -isysroot $VLC_APPLE_SDK_PATH $1"\n'
    '    if [ "${VLC_BUILD_CATALYST:-0}" -gt "0" ]; then\n'
    '        clike_flags+=" -iframework ${VLC_APPLE_SDK_PATH}/System/iOSSupport/System/Library/Frameworks"\n'
    '    fi\n'
    '\n'
    '    local vlc_cppflags'
)

# NOTE: The previous patches #6 and #7 used to conditionally add
# VLC_DEPLOYMENT_TARGET_CFLAG to CPPFLAGS for Catalyst only. That fix is now
# unconditional (all platforms) via patch_vlc_cppflags_version_min below,
# since contrib CFLAGS overrides (notably gsm) leak the host SDK's default
# minos into every simulator/device build, not just Catalyst.

# 6. Add Catalyst-specific VLC configure options (disable GLES2/EGL
#    since OpenGLES is not available on Mac Catalyst)
content = content.replace(
    'if [ "$VLC_DISABLE_DEBUG" -gt "0" ]; then\n'
    '    VLC_CONFIG_OPTIONS+=( "--disable-debug" )',
    'if [ "$VLC_BUILD_CATALYST" -gt "0" ]; then\n'
    '    VLC_CONFIG_OPTIONS+=( "--disable-gles2" )\n'
    'fi\n'
    '\n'
    'if [ "$VLC_DISABLE_DEBUG" -gt "0" ]; then\n'
    '    VLC_CONFIG_OPTIONS+=( "--disable-debug" )'
)

# 6b. Add Catalyst-specific module removal list. Modules wrapped in
#     #if !TARGET_OS_MACCATALYST compile to empty .a files that would
#     crash the static module list generator.
content = content.replace(
    'elif [ "$VLC_HOST_OS" = "watchos" ]; then\n'
    '    VLC_MODULE_REMOVAL_LIST+=( "${VLC_MODULE_REMOVAL_LIST_WATCHOS[@]}" )\n'
    'fi',
    'elif [ "$VLC_HOST_OS" = "watchos" ]; then\n'
    '    VLC_MODULE_REMOVAL_LIST+=( "${VLC_MODULE_REMOVAL_LIST_WATCHOS[@]}" )\n'
    'fi\n'
    '\n'
    'if [ "$VLC_BUILD_CATALYST" -gt "0" ]; then\n'
    '    VLC_MODULE_REMOVAL_LIST+=( "caeagl_ios" "cvpx_gl" )\n'
    'fi'
)

# 7. Patch gl_common.h to treat Catalyst like macOS for OpenGL includes.
#    On Catalyst, TARGET_OS_IPHONE=1 but OpenGLES headers are unavailable.
#    Using macOS OpenGL headers allows GL modules to compile (they may not
#    initialize at runtime, but VLC falls back to other video outputs).
gl_common_path = build_sh_path.replace(
    'extras/package/apple/build.sh',
    'modules/video_output/opengl/gl_common.h'
)
try:
    with open(gl_common_path, 'r') as f:
        gl_content = f.read()
    gl_content = gl_content.replace(
        '# if !TARGET_OS_IPHONE',
        '# if !TARGET_OS_IPHONE || TARGET_OS_MACCATALYST'
    )
    with open(gl_common_path, 'w') as f:
        f.write(gl_content)
    print('Patched gl_common.h for Catalyst')
except Exception as e:
    print(f'Warning: Could not patch gl_common.h: {e}')

with open(build_sh_path, 'w') as f:
    f.write(content)

# 8. Patch interop_cvpx.m: On Catalyst, TARGET_OS_IPHONE=1 but OpenGLES
#     is unavailable. Replace ALL #if TARGET_OS_IPHONE guards so Catalyst
#     takes the macOS (CGL/IOSurface) code path instead of the EAGL path.
modules_dir = build_sh_path.replace('extras/package/apple/build.sh', 'modules/')
interop_path = modules_dir + 'video_output/opengl/interop_cvpx.m'
try:
    with open(interop_path, 'r') as f:
        ic = f.read()
    ic = ic.replace(
        '#if TARGET_OS_IPHONE',
        '#if TARGET_OS_IPHONE && !TARGET_OS_MACCATALYST'
    )
    with open(interop_path, 'w') as f:
        f.write(ic)
    print('Patched interop_cvpx.m for Catalyst')
except Exception as e:
    print(f'Warning: Could not patch interop_cvpx.m: {e}')

# 9. Patch VLCCVOpenGLProvider.m: both CVOpenGLES (iOS) and CVOpenGL (macOS)
#     texture cache APIs are API_UNAVAILABLE(macCatalyst). Disable the entire
#     module on Catalyst — VLC will use other video output paths (Metal/CALayer).
cvgl_path = modules_dir + 'video_output/apple/VLCCVOpenGLProvider.m'
try:
    with open(cvgl_path, 'r') as f:
        cc = f.read()
    cc = '#include <TargetConditionals.h>\n#if !TARGET_OS_MACCATALYST\n' + cc + '\n#endif /* !TARGET_OS_MACCATALYST */\n'
    with open(cvgl_path, 'w') as f:
        f.write(cc)
    print('Patched VLCCVOpenGLProvider.m for Catalyst')
except Exception as e:
    print(f'Warning: Could not patch VLCCVOpenGLProvider.m: {e}')

# 10. Patch VLCOpenGLES2VideoView.m: entire file is EAGL/OpenGLES iOS view.
#     Wrap everything in #if !TARGET_OS_MACCATALYST so it compiles to empty .o
eagl_path = modules_dir + 'video_output/apple/VLCOpenGLES2VideoView.m'
try:
    with open(eagl_path, 'r') as f:
        ec = f.read()
    ec = '#include <TargetConditionals.h>\n#if !TARGET_OS_MACCATALYST\n' + ec + '\n#endif /* !TARGET_OS_MACCATALYST */\n'
    with open(eagl_path, 'w') as f:
        f.write(ec)
    print('Patched VLCOpenGLES2VideoView.m for Catalyst')
except Exception as e:
    print(f'Warning: Could not patch VLCOpenGLES2VideoView.m: {e}')

# 11. Patch ci_filters.m: uses #if !TARGET_OS_IPHONE for CGL vs EAGL.
#     On Catalyst, we want the CGL (macOS) path since OpenGLES is unavailable.
ci_path = modules_dir + 'video_filter/ci_filters.m'
try:
    with open(ci_path, 'r') as f:
        cf = f.read()
    cf = cf.replace(
        '#if !TARGET_OS_IPHONE\n    CGLContextObj',
        '#if !TARGET_OS_IPHONE || TARGET_OS_MACCATALYST\n    CGLContextObj'
    )
    cf = cf.replace(
        '#if !TARGET_OS_IPHONE\n        CGLPixelFormatAttribute',
        '#if !TARGET_OS_IPHONE || TARGET_OS_MACCATALYST\n        CGLPixelFormatAttribute'
    )
    cf = cf.replace(
        '#if !TARGET_OS_IPHONE\n    if (ctx->cgl_context)',
        '#if !TARGET_OS_IPHONE || TARGET_OS_MACCATALYST\n    if (ctx->cgl_context)'
    )
    with open(ci_path, 'w') as f:
        f.write(cf)
    print('Patched ci_filters.m for Catalyst')
except Exception as e:
    print(f'Warning: Could not patch ci_filters.m: {e}')

# 12. Patch decoder.c (videotoolbox): kCVPixelBufferOpenGLESCompatibilityKey
#     is API_UNAVAILABLE(macCatalyst). Add !TARGET_OS_MACCATALYST guard.
decoder_path = modules_dir + 'codec/videotoolbox/decoder.c'
try:
    with open(decoder_path, 'r') as f:
        dc = f.read()
    dc = dc.replace(
        '#elif !defined(TARGET_OS_VISION) || !TARGET_OS_VISION\n'
        '    CFDictionarySetValue(destinationPixelBufferAttributes,\n'
        '                         kCVPixelBufferOpenGLESCompatibilityKey,',
        '#elif (!defined(TARGET_OS_VISION) || !TARGET_OS_VISION) && !TARGET_OS_MACCATALYST\n'
        '    CFDictionarySetValue(destinationPixelBufferAttributes,\n'
        '                         kCVPixelBufferOpenGLESCompatibilityKey,'
    )
    with open(decoder_path, 'w') as f:
        f.write(dc)
    print('Patched decoder.c for Catalyst')
except Exception as e:
    print(f'Warning: Could not patch decoder.c: {e}')

# 13. Patch VLCSampleBufferDisplay.m: same kCVPixelBufferOpenGLESCompatibilityKey
#     issue, but uses matched arrays (keys[] and values[]) that must stay in sync.
sbd_path = modules_dir + 'video_output/apple/VLCSampleBufferDisplay.m'
try:
    with open(sbd_path, 'r') as f:
        sc = f.read()
    # Fix keys array: skip OpenGLES key on Catalyst
    sc = sc.replace(
        '#elif !defined(TARGET_OS_VISION) || !TARGET_OS_VISION\n'
        '            kCVPixelBufferOpenGLESCompatibilityKey,',
        '#elif (!defined(TARGET_OS_VISION) || !TARGET_OS_VISION) && !TARGET_OS_MACCATALYST\n'
        '            kCVPixelBufferOpenGLESCompatibilityKey,'
    )
    # Fix values array: skip matching value on Catalyst to keep arrays in sync
    sc = sc.replace(
        '#if !defined(TARGET_OS_VISION) || !TARGET_OS_VISION\n'
        '            kCFBooleanTrue\n'
        '#endif',
        '#if (!defined(TARGET_OS_VISION) || !TARGET_OS_VISION) && !TARGET_OS_MACCATALYST\n'
        '            kCFBooleanTrue\n'
        '#endif'
    )
    with open(sbd_path, 'w') as f:
        f.write(sc)
    print('Patched VLCSampleBufferDisplay.m for Catalyst')
except Exception as e:
    print(f'Warning: Could not patch VLCSampleBufferDisplay.m: {e}')

print('Catalyst patches applied successfully')
PYEOF

    info "VLC build system patched for Mac Catalyst"
}

# --- Step 1: Clone VLC source ---
info "Setting up VLC source..."
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [ ! -d "vlc" ]; then
    info "Cloning VLC from ${VLC_REPO}..."
    git clone "${VLC_REPO}" --branch "${VLC_BRANCH}" --single-branch vlc
    cd vlc
    git checkout -B build "${VLC_HASH}"
    cd ..
else
    cd vlc
    # Only reset if HEAD isn't already at the pinned commit. An unconditional
    # `git reset --hard` wipes our in-tree patches every run, forcing every
    # downstream patch function to re-apply and all per-platform build dirs
    # to rebuild. VideoLAN's GitLab also doesn't allow fetching by raw SHA,
    # so skip the fetch unless the commit is missing locally.
    CURRENT_HEAD=$(git rev-parse --verify HEAD 2>/dev/null || echo "")
    TARGET_SHA=$(git rev-parse --verify "${VLC_HASH}^{commit}" 2>/dev/null || echo "")
    if [ -z "$TARGET_SHA" ]; then
        info "Commit ${VLC_HASH} missing locally; fetching..."
        git fetch origin "${VLC_BRANCH}"
        TARGET_SHA=$(git rev-parse --verify "${VLC_HASH}^{commit}")
    fi
    if [ "$CURRENT_HEAD" != "$TARGET_SHA" ]; then
        info "VLC source at wrong commit, resetting to ${VLC_HASH}..."
        git reset --hard "${VLC_HASH}"
    else
        info "VLC source already at ${VLC_HASH}"
    fi
    cd ..
fi

VLC_SRC="${BUILD_DIR}/vlc"

# --- Step 1b: Apply patches ---
if [ -n "${PATCHES_DIR}" ] && [ -d "${PATCHES_DIR}" ]; then
    info "Applying patches from ${PATCHES_DIR}..."
    cd "${VLC_SRC}"
    for patch in "${PATCHES_DIR}"/*.patch; do
        if [ -f "$patch" ]; then
            patch_name=$(basename "$patch")
            if git apply --check "$patch" 2>/dev/null; then
                git apply "$patch"
                info "  Applied: ${patch_name}"
            else
                info "  Skipped (already applied or conflicts): ${patch_name}"
            fi
        fi
    done
    cd "${BUILD_DIR}"
fi

# --- Step 1c: Patch VLC snapshot conversion owner ---
# VLC's snapshot path can convert a hardware/opaque picture to RGBA in order
# to blend a rendered subpicture into the saved PNG. At the pinned libVLC
# revision, that conversion filter chain is created with a video owner whose
# buffer allocator is NULL, but filter_chain_NewVideo() asserts that a parent
# video owner must provide one. This trips when snapshots are taken while SPU
# overlays/subtitles are active. Give the snapshot-only conversion chain a
# plain software picture allocator so the assertion and the conversion both
# have a valid output buffer.
patch_vlc_snapshot_filter_owner() {
    local VIDEO_OUTPUT_C="${VLC_SRC}/src/video_output/video_output.c"

    if grep -q 'VoutSnapshotFilterNewPicture' "$VIDEO_OUTPUT_C"; then
        info "VLC snapshot filter owner already patched"
        return 0
    fi

    info "Patching VLC snapshot filter owner buffer allocator..."

    python3 - "$VIDEO_OUTPUT_C" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

needle = '''static const struct filter_video_callbacks vout_video_cbs = {
    NULL, VoutHoldDecoderDevice,
};
'''

replacement = '''static picture_t *VoutSnapshotFilterNewPicture(filter_t *filter)
{
    return picture_NewFromFormat(&filter->fmt_out.video);
}

static const struct filter_video_callbacks vout_video_cbs = {
    VoutSnapshotFilterNewPicture, VoutHoldDecoderDevice,
};
'''

if needle not in content:
    raise SystemExit('snapshot filter callback block not found - VLC video_output.c shape changed')

content = content.replace(needle, replacement, 1)

with open(path, 'w') as f:
    f.write(content)

print('Snapshot filter owner patched successfully')
PYEOF

    info "VLC snapshot filter owner patched"
}

patch_vlc_snapshot_filter_owner

# --- Step 1d: Patch VLC for Mac Catalyst support ---
if [ "$BUILD_CATALYST" = "yes" ]; then
    patch_vlc_for_catalyst
fi

# --- Step 1e: Patch LDFLAGS to include -isysroot ---
# On Xcode 26+, the linker requires an explicit -isysroot
# to find system libraries (libSystem, etc.). VLC's build.sh omits this from
# LDFLAGS, causing FFmpeg's configure (and others) to fail with:
#   ld: library 'System' not found
patch_vlc_ldflags() {
    local BUILD_SH="${VLC_SRC}/extras/package/apple/build.sh"

    if grep -q 'LDFLAGS=.*-isysroot.*VLC_APPLE_SDK_PATH' "$BUILD_SH"; then
        info "VLC build.sh LDFLAGS already patched"
        return 0
    fi

    info "Patching VLC build.sh to add -isysroot to LDFLAGS..."

    python3 - "$BUILD_SH" << 'PYEOF'
import sys

build_sh_path = sys.argv[1]

with open(build_sh_path, 'r') as f:
    content = f.read()

# 1. Fix LDFLAGS in set_host_envvars(): add -isysroot $VLC_APPLE_SDK_PATH
content = content.replace(
    '    export LDFLAGS="$VLC_DEPLOYMENT_TARGET_LDFLAG $VLC_DEPLOYMENT_TARGET_CFLAG -arch $VLC_HOST_ARCH ${bitcode_flag}"',
    '    export LDFLAGS="$VLC_DEPLOYMENT_TARGET_LDFLAG $VLC_DEPLOYMENT_TARGET_CFLAG -arch $VLC_HOST_ARCH -isysroot $VLC_APPLE_SDK_PATH ${bitcode_flag}"'
)

# 2. Fix vlc_ldflags in write_config_mak(): add -isysroot $VLC_APPLE_SDK_PATH
content = content.replace(
    '    local vlc_ldflags="$VLC_DEPLOYMENT_TARGET_LDFLAG $VLC_DEPLOYMENT_TARGET_CFLAG  -arch $VLC_HOST_ARCH"',
    '    local vlc_ldflags="$VLC_DEPLOYMENT_TARGET_LDFLAG $VLC_DEPLOYMENT_TARGET_CFLAG  -arch $VLC_HOST_ARCH -isysroot $VLC_APPLE_SDK_PATH"'
)

with open(build_sh_path, 'w') as f:
    f.write(content)

print('LDFLAGS patched successfully')
PYEOF

    info "VLC build.sh LDFLAGS patched"
}

patch_vlc_ldflags

# Propagate VLC_DEPLOYMENT_TARGET_CFLAG through CPPFLAGS so contribs that
# override CFLAGS (notably `gsm` — see contrib/src/gsm/rules.mak, which sets
# its own CFLAGS via the `Makefile` overrides shipped with the gsm source)
# still receive the platform version-min flag. Without this, those contribs
# compile with the host SDK's default minos, producing LC_BUILD_VERSION
# entries like `minos 26.4` inside a library meant for deployment target
# 18.0 — the linker then warns "built for newer 'X' version than being linked".
#
# autotools and most contrib Makefiles pass CPPFLAGS to the compiler alongside
# CFLAGS, so adding the flag here survives a CFLAGS-override in a contrib.
patch_vlc_cppflags_version_min() {
    local BUILD_SH="${VLC_SRC}/extras/package/apple/build.sh"

    # Use a fixed-string (-F) check tied to this patch's exact output, so an
    # older Catalyst-only variant (which wrote `CPPFLAGS="$VLC_DEPLOYMENT_TARGET_CFLAG $CPPFLAGS"`
    # inside an `if` block) doesn't false-positive and skip the unconditional
    # fix that device + simulator + macOS slices need.
    if grep -qF 'export CPPFLAGS="$VLC_DEPLOYMENT_TARGET_CFLAG -arch' "$BUILD_SH"; then
        info "VLC build.sh CPPFLAGS already patched for version-min"
        return 0
    fi

    info "Patching VLC build.sh to add version-min to CPPFLAGS..."

    python3 - "$BUILD_SH" << 'PYEOF'
import sys

build_sh_path = sys.argv[1]

with open(build_sh_path, 'r') as f:
    content = f.read()

# set_host_envvars(): CPPFLAGS used by contribs that inherit the exported env.
before = (
    '    export CPPFLAGS="-arch $VLC_HOST_ARCH -isysroot $VLC_APPLE_SDK_PATH"\n'
)
after = (
    '    export CPPFLAGS="$VLC_DEPLOYMENT_TARGET_CFLAG -arch $VLC_HOST_ARCH -isysroot $VLC_APPLE_SDK_PATH"\n'
)
if before not in content:
    raise SystemExit('set_host_envvars CPPFLAGS line not found — VLC build.sh shape changed')
content = content.replace(before, after, 1)

# write_config_mak(): vlc_cppflags written into config.mak for contribs that
# consume the mak file directly instead of the exported env.
before = (
    '    local vlc_cppflags="-arch $VLC_HOST_ARCH -isysroot $VLC_APPLE_SDK_PATH"\n'
)
after = (
    '    local vlc_cppflags="$VLC_DEPLOYMENT_TARGET_CFLAG -arch $VLC_HOST_ARCH -isysroot $VLC_APPLE_SDK_PATH"\n'
)
if before not in content:
    raise SystemExit('write_config_mak vlc_cppflags line not found — VLC build.sh shape changed')
content = content.replace(before, after, 1)

with open(build_sh_path, 'w') as f:
    f.write(content)

print('CPPFLAGS version-min patched successfully')
PYEOF

    info "VLC build.sh CPPFLAGS patched"
}

patch_vlc_cppflags_version_min

patch_vlc_xros_deployment_target() {
    local BUILD_SH="${VLC_SRC}/extras/package/apple/build.sh"

    if grep -q 'SWIFTVLC_XROS_TARGET_TRIPLE' "$BUILD_SH"; then
        info "VLC build.sh already patched for visionOS deployment target"
        return 0
    fi

    info "Patching VLC build.sh to set visionOS deployment targets..."

    python3 - "$BUILD_SH" << 'PYEOF'
import sys

build_sh_path = sys.argv[1]

with open(build_sh_path, 'r') as f:
    content = f.read()

needle = (
    '# Validate architecture argument\n'
    'validate_architecture "$VLC_HOST_ARCH"\n'
    '\n'
    '# Set triplet (needs to be called after validating the arch)\n'
)
replacement = (
    '# Validate architecture argument\n'
    'validate_architecture "$VLC_HOST_ARCH"\n'
    '\n'
    '# SWIFTVLC_XROS_TARGET_TRIPLE: the pinned VLC build script leaves xrOS\n'
    '# min-version flags empty, which makes clang stamp objects with the SDK\n'
    '# version. Use a target triple so visionOS objects keep SwiftVLC's minimum.\n'
    'if [ "$VLC_HOST_OS" = "xros" ]; then\n'
    '    xros_simulator_suffix=""\n'
    '    if [ -n "$VLC_HOST_PLATFORM_SIMULATOR" ]; then\n'
    '        xros_simulator_suffix="-simulator"\n'
    '    fi\n'
    '    VLC_DEPLOYMENT_TARGET_CFLAG="--target=${VLC_HOST_ARCH}-apple-xros${VLC_DEPLOYMENT_TARGET}${xros_simulator_suffix}"\n'
    '    VLC_DEPLOYMENT_TARGET_LDFLAG="${VLC_DEPLOYMENT_TARGET_CFLAG}"\n'
    'fi\n'
    '\n'
    '# Set triplet (needs to be called after validating the arch)\n'
)
if needle not in content:
    raise SystemExit('architecture validation block not found — VLC build.sh shape changed')

content = content.replace(needle, replacement, 1)

with open(build_sh_path, 'w') as f:
    f.write(content)

print('visionOS deployment target patch applied successfully')
PYEOF

    info "VLC build.sh visionOS deployment target patched"
}

if [ "$BUILD_VISIONOS" = "yes" ]; then
    patch_vlc_xros_deployment_target
fi

patch_vlc_deployment_targets() {
    local BUILD_CONF="${VLC_SRC}/extras/package/apple/build.conf"

    info "Patching VLC deployment targets to match SwiftVLC's supported minimums..."

    python3 - "$BUILD_CONF" \
        "$SWIFTVLC_MIN_MACOS" \
        "$SWIFTVLC_MIN_IOS" \
        "$SWIFTVLC_MIN_TVOS" \
        "$SWIFTVLC_MIN_CATALYST" \
        "$SWIFTVLC_MIN_VISIONOS" << 'PYEOF'
import re
import sys

build_conf_path, macos, ios, tvos, catalyst, visionos = sys.argv[1:]

with open(build_conf_path, 'r') as f:
    content = f.read()

replacements = {
    r'^export VLC_DEPLOYMENT_TARGET_MACOSX=.*$': f'export VLC_DEPLOYMENT_TARGET_MACOSX="{macos}"',
    r'^export VLC_DEPLOYMENT_TARGET_IOS=.*$': f'export VLC_DEPLOYMENT_TARGET_IOS="{ios}"',
    r'^export VLC_DEPLOYMENT_TARGET_IOS_SIMULATOR=.*$': f'export VLC_DEPLOYMENT_TARGET_IOS_SIMULATOR="{ios}"',
    r'^export VLC_DEPLOYMENT_TARGET_TVOS=.*$': f'export VLC_DEPLOYMENT_TARGET_TVOS="{tvos}"',
    r'^export VLC_DEPLOYMENT_TARGET_TVOS_SIMULATOR=.*$': f'export VLC_DEPLOYMENT_TARGET_TVOS_SIMULATOR="{tvos}"',
    r'^export VLC_DEPLOYMENT_TARGET_XROS=.*$': f'export VLC_DEPLOYMENT_TARGET_XROS="{visionos}"',
}

for pattern, replacement in replacements.items():
    content = re.sub(pattern, replacement, content, flags=re.MULTILINE)

if re.search(r'^export VLC_DEPLOYMENT_TARGET_CATALYST=.*$', content, flags=re.MULTILINE):
    content = re.sub(
        r'^export VLC_DEPLOYMENT_TARGET_CATALYST=.*$',
        f'export VLC_DEPLOYMENT_TARGET_CATALYST="{catalyst}"',
        content,
        flags=re.MULTILINE
    )

with open(build_conf_path, 'w') as f:
    f.write(content)

print('Deployment targets patched successfully')
PYEOF

    info "VLC deployment targets patched"
}

patch_vlc_deployment_targets

ensure_vlc_lgpl_contrib_options() {
    local BUILD_CONF="${VLC_SRC}/extras/package/apple/build.conf"

    info "Ensuring VLC contrib options stay LGPL-oriented..."

    python3 - "$BUILD_CONF" << 'PYEOF'
import sys
from pathlib import Path

path = Path(sys.argv[1])
content = path.read_text()

required = [
    "--disable-gpl",
    "--disable-gnuv3",
    "--disable-dvdcss",
    "--disable-libdvdcss",
    "--disable-dvdread",
    "--disable-dvdnav",
    "--disable-x264",
    "--disable-x265",
    "--disable-faad",
    "--disable-faad2",
    "--disable-dca",
    "--disable-libdca",
    "--disable-mpeg2",
    "--disable-libmpeg2",
    "--disable-postproc",
]

needle = "export VLC_CONTRIB_OPTIONS_BASE=(\n"
if needle not in content:
    raise SystemExit("VLC_CONTRIB_OPTIONS_BASE block not found - VLC build.conf shape changed")

start = content.index(needle) + len(needle)
end = content.index(")", start)
base_block = content[start:end]
missing = [option for option in required if option not in base_block]
if not missing:
    print("LGPL contrib options already present")
    raise SystemExit(0)

insert = "".join(f"    {option}\n" for option in missing)
content = content[:start] + insert + content[start:]
path.write_text(content)
print("Inserted LGPL contrib options: " + ", ".join(missing))
PYEOF

    info "VLC contrib LGPL options ensured"
}

ensure_vlc_lgpl_contrib_options

verify_vlc_lgpl_configuration() {
    local BUILD_CONF="${VLC_SRC}/extras/package/apple/build.conf"
    local required_options=(
        --disable-gpl
        --disable-gnuv3
        --disable-dvdcss
        --disable-libdvdcss
        --disable-dvdread
        --disable-dvdnav
        --disable-x264
        --disable-x265
        --disable-faad
        --disable-faad2
        --disable-dca
        --disable-libdca
        --disable-mpeg2
        --disable-libmpeg2
        --disable-postproc
    )
    local option

    info "Verifying VLC GPL exclusion options..."

    local base_block
    base_block=$(awk '
        /^export VLC_CONTRIB_OPTIONS_BASE=\(/ { in_base = 1 }
        in_base { print }
        in_base && /^\)/ { exit }
    ' "$BUILD_CONF")

    if [ -z "$base_block" ]; then
        error "VLC_CONTRIB_OPTIONS_BASE block not found in VLC build.conf."
    fi

    for option in "${required_options[@]}"; do
        if ! grep -qF -- "$option" <<< "$base_block"; then
            error "Required LGPL-oriented contrib option missing from VLC build.conf: $option"
        fi
    done

    if grep -En -- '--enable-(gpl|gnuv3|dvdcss|libdvdcss|dvdread|dvdnav|x264|x265|faad|faad2|dca|libdca|mpeg2|libmpeg2|postproc)([^A-Za-z0-9_-]|$)' "$BUILD_CONF"; then
        error "VLC build.conf contains a prohibited GPL-oriented enable option."
    fi

    info "VLC GPL exclusion options verified"
}

verify_vlc_lgpl_configuration

# --- Step 1f: Force libtool --tag=CC for Objective-C convenience library ---
# VLC's src/Makefile.am builds libvlccore_objc.la from .m files, but doesn't
# tell libtool which tag to use. On libtool 2.5+ (current Homebrew), libtool
# can't infer the tag from the compile command and fails with:
#   libtool: compile: unable to infer tagged configuration
#   libtool:   error: specify a tag with '--tag'
# Older libtool versions were more permissive. LT_LANG([Objective C]) isn't a
# thing (libtool only supports C/CXX/F77/FC/GCJ/RC), so the right fix is to
# set per-target LIBTOOLFLAGS so automake emits `libtool --tag=CC` for the
# .m compiles. Objective C is a C superset; --tag=CC is exactly right.
patch_vlc_objc_libtool() {
    # Content-based idempotency: `git reset --hard` wipes our edits but leaves
    # marker files intact, so the check must look at actual file contents.
    if grep -q 'libvlccore_objc_la_LIBTOOLFLAGS' "${VLC_SRC}/src/Makefile.am"; then
        info "VLC Makefile.am files already patched for OBJC libtool tag"
        return 0
    fi

    info "Scanning Makefile.am files for .m sources to add --tag=CC..."

    python3 - "$VLC_SRC" << 'PYEOF'
import re
import sys
from pathlib import Path

vlc_root = Path(sys.argv[1])
patched = 0

# Matches "target_name_SOURCES = ..." or "target_name_SOURCES += ..."
# The RHS may span multiple lines via backslash-newline continuations.
sources_re = re.compile(
    r'^([A-Za-z_][A-Za-z0-9_]*?)_SOURCES\s*\+?=\s*((?:[^\n\\]|\\\n|\\.)*)',
    re.MULTILINE
)

for mf in sorted(vlc_root.rglob('Makefile.am')):
    # Skip the build-tools tree and anything under contribs
    if 'extras/tools' in str(mf) or 'contrib/' in str(mf):
        continue

    text = mf.read_text()
    targets_with_m = set()

    for m in sources_re.finditer(text):
        target = m.group(1)
        rhs = m.group(2)
        # Flatten line continuations
        rhs_flat = re.sub(r'\\\n', ' ', rhs)
        # A source ending in .m (not .mm for C++) — and not part of .mk/.mo etc.
        if re.search(r'(^|\s)[^\s]+\.m(\s|$)', rhs_flat):
            targets_with_m.add(target)

    if not targets_with_m:
        continue

    additions = []
    for target in sorted(targets_with_m):
        tag_re = re.compile(
            rf'^{re.escape(target)}_LIBTOOLFLAGS\s*=', re.MULTILINE
        )
        if tag_re.search(text):
            continue
        additions.append(f'{target}_LIBTOOLFLAGS = --tag=CC')

    if not additions:
        continue

    if not text.endswith('\n'):
        text += '\n'
    text += (
        '\n# libtool 2.5+ cannot infer the tag for .m compiles; force CC.\n'
        + '\n'.join(additions) + '\n'
    )
    mf.write_text(text)
    patched += 1
    print(f'  patched: {mf.relative_to(vlc_root)} ({len(additions)} target(s))')

print(f'Patched {patched} Makefile.am file(s) for OBJC libtool tag')
PYEOF

    # Force ./bootstrap to regenerate configure/Makefile.in so the new
    # per-target LIBTOOLFLAGS gets picked up. Also wipe per-platform build
    # dirs so their stale generated Makefiles are thrown away.
    rm -f "${VLC_SRC}/configure"
    rm -rf "${VLC_SRC}"/build-iphoneos-* \
           "${VLC_SRC}"/build-iphonesimulator-* \
           "${VLC_SRC}"/build-appletvos-* \
           "${VLC_SRC}"/build-appletvsimulator-* \
           "${VLC_SRC}"/build-xros-* \
           "${VLC_SRC}"/build-xrsimulator-* \
           "${VLC_SRC}"/build-macosx-* \
           "${VLC_SRC}"/build-maccatalyst-*

    info "Makefile.am files patched; configure + platform build dirs cleared"
}

patch_vlc_objc_libtool

# --- Step 1g: Disable Rust-based contribs ---
# VLC contribs pin cargo-c 0.9.29, which transitively pulls time 0.3.31 and
# fails type inference for Box<_> under the supported Rust toolchain.
# The only Rust contrib we'd get on Apple is rav1e (AV1 *encoder*); we already
# have dav1d for AV1 *decoding*, which is what matters for playback. iOS and
# tvOS already skip Rust (Tier 3 targets); this unifies macOS + Catalyst.
patch_vlc_disable_rust() {
    local MAIN_RUST_MAK="${VLC_SRC}/contrib/src/main-rust.mak"

    if grep -q 'SWIFTVLC_DISABLE_RUST' "$MAIN_RUST_MAK"; then
        info "VLC Rust contribs already disabled"
        return 0
    fi

    info "Disabling VLC Rust-based contribs..."

    python3 - "$MAIN_RUST_MAK" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()
content = content.replace(
    'BUILD_RUST="1"',
    '# SWIFTVLC_DISABLE_RUST: cargo-c 0.9.29 pulls time 0.3.31, which fails\n'
    '# type inference for Box<_>; rav1e is an encoder and dav1d handles\n'
    '# AV1 decoding. Never set BUILD_RUST.\n'
    '# BUILD_RUST="1"'
)
with open(path, 'w') as f:
    f.write(content)
PYEOF

    info "VLC contrib/src/main-rust.mak patched to skip Rust contribs"
}

patch_vlc_disable_rust

# --- Step 2: Build tools ---
info "Building VLC build tools..."
export PATH="${VLC_SRC}/extras/tools/build/bin:$PATH"
cd "${VLC_SRC}/extras/tools"
./bootstrap
make ${MAKEFLAGS}
cd "${BUILD_DIR}"

# --- Step 3: Compile libVLC per platform/arch ---
#
# Force autoconf to treat Linux-only syscalls as unavailable. iOS Simulator
# SDK 26+ exports dup3/pipe2 from libSystem (so autoconf's link test says
# "yes"), but the iOS headers don't declare them — leading to
# "use of undeclared identifier 'dup3'" during src/posix/filesystem.c.
# Device builds correctly detect "no"; simulator SDKs that expose those
# symbols get confused. VLC's code has proper #else fallbacks.
export ac_cv_func_dup3=no
export ac_cv_func_pipe2=no

compile_libvlc() {
    local ARCH="$1"
    local PLATFORM="$2"
    local ACTUAL_ARCH
    ACTUAL_ARCH=$(get_actual_arch "$ARCH")

    local SDK_VERSION
    SDK_VERSION=$(xcrun --sdk "${PLATFORM}" --show-sdk-version)

    info "Compiling libVLC for ${ACTUAL_ARCH} (${PLATFORM}, SDK ${SDK_VERSION})..."
    local platform_start=$(date +%s)

    # Use the normalized arch name for the build directory
    # This matches what VLC's build.sh creates internally
    local BUILDDIR="${VLC_SRC}/build-${PLATFORM}-${ACTUAL_ARCH}"
    mkdir -p "${BUILDDIR}"
    cd "${BUILDDIR}"

    "${VLC_SRC}/extras/package/apple/build.sh" \
        --arch="${ARCH}" \
        --sdk="${PLATFORM}${SDK_VERSION}" \
        --enable-shared \
        ${MAKEFLAGS}

    cd "${BUILD_DIR}"

    local platform_end=$(date +%s)
    local platform_secs=$((platform_end - platform_start))
    local platform_mins=$((platform_secs / 60))
    info "Finished ${ACTUAL_ARCH} (${PLATFORM}) in ${platform_mins}m$((platform_secs % 60))s"
}

# Compile libVLC for Mac Catalyst.
# Uses the macOS SDK with --catalyst flag to set the macabi target triple.
compile_libvlc_catalyst() {
    local ARCH="$1"
    local ACTUAL_ARCH
    ACTUAL_ARCH=$(get_actual_arch "$ARCH")

    local SDK_VERSION
    SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)

    info "Compiling libVLC for ${ACTUAL_ARCH} (Mac Catalyst, macOS SDK ${SDK_VERSION})..."
    local platform_start=$(date +%s)

    # Use a separate build directory to avoid colliding with native macOS builds
    local BUILDDIR="${VLC_SRC}/build-maccatalyst-${ACTUAL_ARCH}"
    mkdir -p "${BUILDDIR}"
    cd "${BUILDDIR}"

    "${VLC_SRC}/extras/package/apple/build.sh" \
        --arch="${ARCH}" \
        --sdk="macosx${SDK_VERSION}" \
        --catalyst \
        ${MAKEFLAGS}

    cd "${BUILD_DIR}"

    local platform_end=$(date +%s)
    local platform_secs=$((platform_end - platform_start))
    local platform_mins=$((platform_secs / 60))
    info "Finished ${ACTUAL_ARCH} (Mac Catalyst) in ${platform_mins}m$((platform_secs % 60))s"
}

vlc_install_dir() {
    local ARCH="$1"
    local PLATFORM="$2"
    local ACTUAL_ARCH
    ACTUAL_ARCH=$(get_actual_arch "$ARCH")

    local SDK_VERSION
    SDK_VERSION=$(xcrun --sdk "${PLATFORM}" --show-sdk-version)

    echo "${VLC_SRC}/build-${PLATFORM}-${ACTUAL_ARCH}/vlc-${PLATFORM}${SDK_VERSION}-${ACTUAL_ARCH}"
}

write_framework_info_plist() {
    local FRAMEWORK_DIR="$1"
    local PLATFORM_NAME="$2"
    local MINIMUM_OS="$3"

    cat > "${FRAMEWORK_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>libvlc</string>
  <key>CFBundleIdentifier</key>
  <string>org.videolan.libvlc</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>libvlc</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>4.0.0</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>${PLATFORM_NAME}</string>
  </array>
  <key>CFBundleVersion</key>
  <string>4.0.0</string>
  <key>MinimumOSVersion</key>
  <string>${MINIMUM_OS}</string>
</dict>
</plist>
EOF
}

copy_vlc_headers() {
    local FRAMEWORK_DIR="$1"

    mkdir -p "${FRAMEWORK_DIR}/Headers"
    cp -R "${REPO_ROOT}/Sources/CLibVLC/include/vlc" "${FRAMEWORK_DIR}/Headers/"
}

stage_dynamic_framework() {
    local INSTALL_DIR="$1"
    local FRAMEWORK_DIR="$2"
    local PLATFORM_NAME="$3"
    local MINIMUM_OS="$4"

    local LIB_DIR="${INSTALL_DIR}/lib"
    local MAIN_DYLIB="${LIB_DIR}/libvlc.dylib"

    [ -f "$MAIN_DYLIB" ] || error "Missing dynamic libVLC binary: $MAIN_DYLIB"

    rm -rf "$FRAMEWORK_DIR"
    mkdir -p "$FRAMEWORK_DIR"

    cp -L "$MAIN_DYLIB" "${FRAMEWORK_DIR}/libvlc"

    while IFS= read -r dylib; do
        local name
        name=$(basename "$dylib")
        case "$name" in
            libvlc.dylib|libvlc.[0-9]*.dylib) continue ;;
        esac
        cp -L "$dylib" "${FRAMEWORK_DIR}/${name}"
    done < <(find "$LIB_DIR" -maxdepth 1 \( -type f -o -type l \) -name "*.dylib*" -print)

    if [ -d "${LIB_DIR}/vlc/plugins" ]; then
        mkdir -p "${FRAMEWORK_DIR}/plugins"
        cp -R "${LIB_DIR}/vlc/plugins/." "${FRAMEWORK_DIR}/plugins/"
        find "${FRAMEWORK_DIR}/plugins" -name "*.la" -delete
    fi

    if [ -d "${INSTALL_DIR}/share" ]; then
        mkdir -p "${FRAMEWORK_DIR}/Resources"
        cp -R "${INSTALL_DIR}/share" "${FRAMEWORK_DIR}/Resources/"
    fi

    copy_vlc_headers "$FRAMEWORK_DIR"
    write_framework_info_plist "$FRAMEWORK_DIR" "$PLATFORM_NAME" "$MINIMUM_OS"
}

merge_dynamic_frameworks() {
    local PRIMARY_FRAMEWORK="$1"
    local SECONDARY_FRAMEWORK="$2"
    local OUTPUT_FRAMEWORK="$3"

    rm -rf "$OUTPUT_FRAMEWORK"
    mkdir -p "$(dirname "$OUTPUT_FRAMEWORK")"
    cp -R "$PRIMARY_FRAMEWORK" "$OUTPUT_FRAMEWORK"

    while IFS= read -r primary_file; do
        local relative_path="${primary_file#${PRIMARY_FRAMEWORK}/}"
        local secondary_file="${SECONDARY_FRAMEWORK}/${relative_path}"
        local output_file="${OUTPUT_FRAMEWORK}/${relative_path}"

        if ! lipo -info "$primary_file" >/dev/null 2>&1; then
            continue
        fi

        if [ -f "$secondary_file" ]; then
            lipo "$primary_file" "$secondary_file" -create -output "$output_file"
        else
            info "Keeping arm64-only simulator Mach-O: $relative_path"
        fi
    done < <(find "$PRIMARY_FRAMEWORK" -type f -print)

    while IFS= read -r secondary_file; do
        local relative_path="${secondary_file#${SECONDARY_FRAMEWORK}/}"
        local primary_file="${PRIMARY_FRAMEWORK}/${relative_path}"
        local output_file="${OUTPUT_FRAMEWORK}/${relative_path}"

        if ! lipo -info "$secondary_file" >/dev/null 2>&1; then
            continue
        fi

        if [ ! -f "$primary_file" ]; then
            mkdir -p "$(dirname "$output_file")"
            cp -L "$secondary_file" "$output_file"
            info "Added x86_64-only simulator Mach-O: $relative_path"
        fi
    done < <(find "$SECONDARY_FRAMEWORK" -type f -print)
}

rewrite_framework_install_names() {
    local FRAMEWORK_DIR="$1"

    python3 - "$FRAMEWORK_DIR" << 'PYEOF'
import os
import subprocess
import sys
from pathlib import Path

framework = Path(sys.argv[1]).resolve()
main_binary = framework / "libvlc"

def is_macho(path: Path) -> bool:
    result = subprocess.run(["lipo", "-info", str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return result.returncode == 0

machos = [path for path in framework.rglob("*") if path.is_file() and is_macho(path)]
local_paths = {path.name: path for path in machos if path.name != "libvlc"}

if main_binary.exists() and is_macho(main_binary):
    subprocess.run(["install_name_tool", "-id", "@rpath/libvlc.framework/libvlc", str(main_binary)], check=True)

for macho in machos:
    if macho.name != "libvlc":
        subprocess.run(["install_name_tool", "-id", f"@loader_path/{macho.name}", str(macho)], check=True)

    otool = subprocess.run(["otool", "-L", str(macho)], check=True, capture_output=True, text=True)
    for line in otool.stdout.splitlines()[1:]:
        dependency = line.strip().split(" ", 1)[0]
        dependency_name = Path(dependency).name
        if dependency_name == "libvlc.dylib" or (dependency_name.startswith("libvlc.") and dependency_name.endswith(".dylib")):
            replacement = "@rpath/libvlc.framework/libvlc"
        elif dependency_name in local_paths:
            relative_dependency = os.path.relpath(local_paths[dependency_name], macho.parent)
            replacement = f"@loader_path/{relative_dependency}"
        else:
            continue
        if dependency != replacement:
            subprocess.run(["install_name_tool", "-change", dependency, replacement, str(macho)], check=True)
PYEOF
}

verify_no_static_archives() {
    if find "${OUTPUT_DIR}/libvlc.xcframework" -name "*.a" -print -quit | grep -q .; then
        error "Static archives found in libvlc.xcframework; expected dynamic frameworks only."
    fi
}

verify_no_libtool_archives() {
    if find "${OUTPUT_DIR}/libvlc.xcframework" -name "*.la" -print -quit | grep -q .; then
        error "Libtool archives found in libvlc.xcframework; expected dylibs only."
    fi
}

verify_dynamic_frameworks() {
    local slices=(
        "ios-arm64"
        "ios-arm64_x86_64-simulator"
    )
    local slice binary

    info "Verifying dynamic framework slices..."
    for slice in "${slices[@]}"; do
        binary="${OUTPUT_DIR}/libvlc.xcframework/${slice}/libvlc.framework/libvlc"
        [ -f "$binary" ] || error "Missing libvlc framework binary for slice: $slice"
        if ! file "$binary" | grep -q "dynamically linked shared library"; then
            file "$binary" >&2
            error "libvlc framework binary is not a dynamic library for slice: $slice"
        fi
        info "  ${slice}: $(lipo -info "$binary")"
    done
}

verify_deployment_targets() {
    info "Verifying deployment-target minimums in xcframework..."

    local slices=(
        "ios-arm64:${SWIFTVLC_MIN_IOS}"
        "ios-arm64_x86_64-simulator:${SWIFTVLC_MIN_IOS}"
    )

    local had_failure=0
    local slice_spec slice expected binary max_minos highest
    for slice_spec in "${slices[@]}"; do
        slice="${slice_spec%%:*}"
        expected="${slice_spec#*:}"
        binary="${OUTPUT_DIR}/libvlc.xcframework/${slice}/libvlc.framework/libvlc"
        [ -f "$binary" ] || continue

        max_minos=$(otool -l "$binary" 2>/dev/null \
            | awk '/^[[:space:]]*cmd LC_BUILD_VERSION/{flag=1; next} flag && /^[[:space:]]*minos /{print $2; flag=0}' \
            | sort -V | tail -1)

        if [ -z "$max_minos" ]; then
            warn "  ${slice}: no LC_BUILD_VERSION found (skipping)"
            continue
        fi

        highest=$(printf '%s\n%s\n' "$max_minos" "$expected" | sort -V | tail -1)
        if [ "$highest" = "$expected" ]; then
            info "  ${slice}: minos=${max_minos} <= deployment=${expected}"
        else
            warn "  ${slice}: minos=${max_minos} > deployment=${expected}"
            had_failure=1
        fi
    done

    if [ "$had_failure" -eq 1 ]; then
        error "Deployment-target verification failed (see warnings above)."
    fi
}

[ "$BUILD_IOS" = "yes" ] || error "No platforms were built. This fork only supports the default iOS build or --ios-only."

# iOS device (arm64)
compile_libvlc aarch64 iphoneos

# iOS simulator (arm64 + x86_64)
compile_libvlc aarch64 iphonesimulator
compile_libvlc x86_64 iphonesimulator

info "Staging dynamic iOS frameworks..."
FRAMEWORK_BUILD_DIR="${BUILD_DIR}/frameworks"
DEVICE_FRAMEWORK="${FRAMEWORK_BUILD_DIR}/ios-device/libvlc.framework"
SIM_ARM64_FRAMEWORK="${FRAMEWORK_BUILD_DIR}/ios-simulator-arm64/libvlc.framework"
SIM_X86_64_FRAMEWORK="${FRAMEWORK_BUILD_DIR}/ios-simulator-x86_64/libvlc.framework"
SIMULATOR_FRAMEWORK="${FRAMEWORK_BUILD_DIR}/ios-simulator/libvlc.framework"
rm -rf "$FRAMEWORK_BUILD_DIR"

stage_dynamic_framework "$(vlc_install_dir aarch64 iphoneos)" "$DEVICE_FRAMEWORK" "iPhoneOS" "$SWIFTVLC_MIN_IOS"
stage_dynamic_framework "$(vlc_install_dir aarch64 iphonesimulator)" "$SIM_ARM64_FRAMEWORK" "iPhoneSimulator" "$SWIFTVLC_MIN_IOS"
stage_dynamic_framework "$(vlc_install_dir x86_64 iphonesimulator)" "$SIM_X86_64_FRAMEWORK" "iPhoneSimulator" "$SWIFTVLC_MIN_IOS"
merge_dynamic_frameworks "$SIM_ARM64_FRAMEWORK" "$SIM_X86_64_FRAMEWORK" "$SIMULATOR_FRAMEWORK"

rewrite_framework_install_names "$DEVICE_FRAMEWORK"
rewrite_framework_install_names "$SIMULATOR_FRAMEWORK"

info "Creating libvlc.xcframework..."
mkdir -p "${OUTPUT_DIR}"
rm -rf "${OUTPUT_DIR}/libvlc.xcframework"

xcodebuild -create-xcframework \
    -framework "$DEVICE_FRAMEWORK" \
    -framework "$SIMULATOR_FRAMEWORK" \
    -output "${OUTPUT_DIR}/libvlc.xcframework"

# The CLibVLC SPM target provides its own module map and umbrella header.
# Keep the binary framework linkable while avoiding duplicate C module imports.
find "${OUTPUT_DIR}/libvlc.xcframework" -name "module.modulemap" -delete
find "${OUTPUT_DIR}/libvlc.xcframework" -name "CLibVLC.h" -delete

info "Created: ${OUTPUT_DIR}/libvlc.xcframework"

"${SCRIPT_DIR}/verify-libvlc-xcframework.sh" "${OUTPUT_DIR}/libvlc.xcframework"
verify_deployment_targets

echo ""
info "Build complete!"
echo "  XCFramework: ${OUTPUT_DIR}/libvlc.xcframework"
echo "  Architectures:"
find "${OUTPUT_DIR}/libvlc.xcframework" -path "*/libvlc.framework/libvlc" -exec lipo -info {} \;

local_end=$(date +%s)
local_total=$((local_end - BUILD_START_TIME))
local_mins=$((local_total / 60))
echo ""
echo "  Total time: ${local_mins}m$((local_total % 60))s"
echo ""
echo "To use: run 'swift build' in the SwiftVLC directory"
