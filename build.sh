#!/bin/bash
# Builds "Mac TV.app" into ./build
set -euo pipefail
cd "$(dirname "$0")"

# One universal binary: Apple silicon and Intel Macs.
ARCHS=(--arch arm64 --arch x86_64)
BUILD_LOCATION=(--scratch-path "${MACTV_BUILD_DIR:-.build}")
swift build -c release "${ARCHS[@]}" "${BUILD_LOCATION[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" "${BUILD_LOCATION[@]}" --show-bin-path)"

APP="build/Mac TV.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MacTV" "$APP/Contents/MacOS/MacTV"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Icons "$APP/Contents/Resources/Icons"
cp Assets/AppIcon.icns Assets/AppIcon.png "$APP/Contents/Resources/"
# The package's resource bundle (the phone remote's page).
for bundle in "$BIN"/*.bundle; do [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"; done
# Sign with the local certificate when it exists (scripts/make-signing-cert.sh), so macOS keeps
# permissions like Accessibility across builds; otherwise sign ad hoc.
IDENTITY="${MACTV_SIGN_IDENTITY:-Mac TV Local Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    # The keychain's items, by a program that never changes (KeysHelper/main.swift): a small app of its own, whole as
    # it is kept, signed exactly as KeysHelper/build.sh signed it to record its hash (Mac TV's certificate, the
    # hardened runtime, no timestamp), so that its hash stays the one the keychain allowed. Only with Mac TV's own
    # certificate, the one the helper answers: any other build has no helper, and calls the keychain itself.
    if [[ "$IDENTITY" == "Mac TV Local Signing" ]]; then
        KEYS="$APP/Contents/Helpers/Mac TV Keys.app"
        mkdir -p "$APP/Contents/Helpers"
        ditto "KeysHelper/Mac TV Keys.app" "$KEYS"
        find "$APP/Contents/Helpers" -name .DS_Store -delete  # Finder's, from looking into it: it would be sealed into its hash
        codesign --force --timestamp=none --options runtime --sign "$IDENTITY" "$KEYS" >/dev/null 2>&1 \
            || { echo "Cannot sign the keys helper" >&2; exit 1; }
    fi
    # The app as a whole, sealing the helper as it is signed (no --deep: the helper is not signed again)
    codesign --force --entitlements Assets/MacTV.entitlements --sign "$IDENTITY" "$APP" >/dev/null
    if [[ -n "${KEYS:-}" ]]; then
        codesign --verify --strict \
            -R='identifier "local.couch.tv" and certificate leaf = H"2eae0495835c9ecddf36371b7a9245f3a87090db"' "$APP"
        # The helper's hash, one per architecture, is the one KeysHelper/build.sh recorded; otherwise the keychain
        # would ask again for every item (KeysHelper/main.swift)
        HASHES="$(for arch in arm64 x86_64; do
            echo "$arch $(codesign -dvvv --arch "$arch" "$KEYS" 2>&1 | sed -n 's/^CDHash=//p')"
        done)"
        if [[ "$HASHES" != "$(cat KeysHelper/cdhash)" ]]; then
            echo "The keys helper's hashes are" >&2; echo "$HASHES" >&2
            echo "not those in KeysHelper/cdhash: see KeysHelper/build.sh" >&2
            exit 1
        fi
    fi
else
    codesign --force --entitlements Assets/MacTV.entitlements --sign - "$APP" >/dev/null
fi

echo "Built $(pwd)/$APP"
