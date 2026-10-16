#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
VERSION="${1:-0.1.0-preview}"
DERIVED_DATA="$ROOT_DIR/.build/PreviewDerivedData"
OUTPUT_DIR="$ROOT_DIR/.build/releases"

if [[ ! "$VERSION" =~ '^[0-9A-Za-z][0-9A-Za-z.-]*$' ]]; then
    print -u2 "Invalid version: $VERSION"
    exit 2
fi

mkdir -p "$ROOT_DIR/.build" "$OUTPUT_DIR"
STAGING_DIR="$(mktemp -d "$ROOT_DIR/.build/preview.XXXXXX")"

cleanup() {
    if [[
        -n "${STAGING_DIR:-}"
        && "$STAGING_DIR" == "$ROOT_DIR"/.build/preview.*
        && -d "$STAGING_DIR"
    ]]; then
        rm -rf -- "$STAGING_DIR"
    fi
}
trap cleanup EXIT HUP INT TERM

xcodebuild \
    -quiet \
    -project "$ROOT_DIR/CodexUsageMenuBar.xcodeproj" \
    -scheme CodexUsageMenuBar \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/CodexUsageMenuBar.app"
PREVIEW_APP="$STAGING_DIR/Agent Usage.app"
EXECUTABLE="$PREVIEW_APP/Contents/MacOS/CodexUsageMenuBar"
ARCHIVE="$OUTPUT_DIR/Agent-Usage-$VERSION-macos-universal.zip"

ditto "$BUILT_APP" "$PREVIEW_APP"
if [[ -n "${AGENT_USAGE_SIGNING_IDENTITY:-}" ]]; then
    zsh "$ROOT_DIR/scripts/sign-app.sh" "$PREVIEW_APP" distribution
else
    print 'Building an ad-hoc-signed, unnotarized test preview (not Developer ID distribution).'
    codesign --force --deep --sign - "$PREVIEW_APP"
fi

codesign --verify --deep --strict "$PREVIEW_APP"
lipo "$EXECUTABLE" -verify_arch arm64 x86_64

ditto \
    -c \
    -k \
    --sequesterRsrc \
    --keepParent \
    "$PREVIEW_APP" \
    "$ARCHIVE"

print "Created $ARCHIVE"
shasum -a 256 "$ARCHIVE"
