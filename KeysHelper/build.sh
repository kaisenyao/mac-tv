#!/bin/bash
# Builds KeysHelper/Mac TV Keys.app, once (main.swift says why it is then kept as it is): the helper from main.swift,
# one universal program (Apple silicon and Intel, as Mac TV), in a small app of its own so that the keychain's window
# shows Mac TV's icon and the name Mac TV Keys beside its question (a bare program shows the system's black "exec"
# picture). Never in the Dock: it has no window, and says so. Then writes KeysHelper/cdhash: its hash once signed as
# the root build.sh signs it, with Mac TV's own certificate and the hardened runtime, which build.sh checks every build
# against. The hash is of the whole app (its program, its Info.plist, its icon), so all of it is kept as it was built.
# Run it only to change the helper on purpose, and only once a release: with a new helper, the keychain asks once
# more for every item.
set -euo pipefail
cd "$(dirname "$0")"
APP="Mac TV Keys.app"
IDENTITY="Mac TV Local Signing"
if ! security find-identity -p codesigning 2>/dev/null | grep -qF "\"$IDENTITY\""; then
    echo "No signing identity \"$IDENTITY\" in the keychain (scripts/make-signing-cert.sh)" >&2
    exit 1
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>local.couch.tv.keys</string>
	<key>CFBundleName</key>
	<string>Mac TV Keys</string>
	<key>CFBundleDisplayName</key>
	<string>Mac TV Keys</string>
	<key>CFBundleExecutable</key>
	<string>Mac TV Keys</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
PLIST
WORK="$(mktemp -d)"
swiftc -O -target arm64-apple-macos14.0 -o "$WORK/arm64" main.swift
swiftc -O -target x86_64-apple-macos14.0 -o "$WORK/x86_64" main.swift
lipo -create "$WORK/arm64" "$WORK/x86_64" -output "$APP/Contents/MacOS/Mac TV Keys"
cp ../Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Kept unsigned here, signed in each build of Mac TV (build.sh): its hash, signed so, is the one recorded
SIGNED="$WORK/$APP"
ditto "$APP" "$SIGNED"
codesign --force --timestamp=none --options runtime --sign "$IDENTITY" "$SIGNED"
# One hash per architecture (the keychain knows the one the Mac runs), as build.sh reads them back
for arch in arm64 x86_64; do
    echo "$arch $(codesign -dvvv --arch "$arch" "$SIGNED" 2>&1 | sed -n 's/^CDHash=//p')"
done > cdhash
rm -rf "$WORK"
echo "Built KeysHelper/$APP; signed, its hashes are:"
cat cdhash
