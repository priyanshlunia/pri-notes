#!/bin/bash
# Build "Pri Notes.app" (release) and install it into ~/Applications.
#
#   scripts/build_app.sh            # build + install + (re)launch
#   scripts/build_app.sh --no-open  # build + install only
#
# Signing: uses $SIGN_IDENTITY if set, else the self-signed "Pri Notes Local Signing"
# certificate in the login keychain (keeps the Accessibility permission valid across rebuilds);
# otherwise signs ad-hoc, in which case Accessibility must be re-granted after every rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Pri Notes"
EXECUTABLE="PriNotes"
# Keep this identifier: the Accessibility grant is tied to it (plus the signing certificate).
BUNDLE_ID="local.prinotes"
DEST="$HOME/Applications/$APP_NAME.app"

cd "$ROOT"
swift build -c release --product PriNotes
BIN="$(swift build -c release --show-bin-path)/PriNotes"

STAGE="$ROOT/.build/$APP_NAME.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/$EXECUTABLE"
cp -R "$ROOT/Resources/mathjax" "$STAGE/Contents/Resources/mathjax"
cp "$ROOT/Resources/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"

cat > "$STAGE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>CFBundleVersion</key><string>110</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>iCloud Drive file link</string>
            <key>CFBundleURLSchemes</key><array><string>shareddocuments</string></array>
        </dict>
    </array>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Default to the local self-signed identity if it exists (see README), else ad-hoc.
if [[ -z "${SIGN_IDENTITY:-}" ]] && security find-identity -p codesigning | grep -q "Pri Notes Local Signing"; then
    SIGN_IDENTITY="Pri Notes Local Signing"
fi
codesign --force --deep --sign "${SIGN_IDENTITY:--}" --identifier "$BUNDLE_ID" "$STAGE"

pkill -x "$EXECUTABLE" 2>/dev/null || true
pkill -x NotesMarkdown 2>/dev/null || true            # builds from before the rename
rm -rf "$HOME/Applications/Notes Markdown.app"        # install from before the rename
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$STAGE" "$DEST"
echo "Installed $DEST"

if [[ "${1:-}" != "--no-open" ]]; then
    sleep 1   # let LaunchServices notice the old instance has quit
    open "$DEST"
fi
