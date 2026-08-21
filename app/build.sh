#!/bin/bash
# Builds TrainYourPokemon.app without Xcode — Command Line Tools are enough.
# A real WidgetKit widget would need an app extension target and therefore the
# full Xcode install; a MenuBarExtra app does not.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$APP_DIR")"
BUILD_DIR="$APP_DIR/.build"
BUNDLE="$APP_DIR/TrainYourPokemon.app"

rm -rf "$BUILD_DIR" "$BUNDLE"
mkdir -p "$BUILD_DIR" "$BUNDLE/Contents/MacOS"

# The app shells out to the engine, so it needs the repo's absolute path.
# Injected at build time rather than hardcoded in the source.
cat > "$BUILD_DIR/Config.swift" <<EOF
enum Config {
    static let repoPath = "$REPO_DIR"
}
EOF

echo "Compiling…"
# Every file under Sources/, so adding one does not need a change here.
swiftc -parse-as-library -O \
    -o "$BUNDLE/Contents/MacOS/TrainYourPokemon" \
    "$APP_DIR"/Sources/*.swift \
    "$BUILD_DIR/Config.swift"

cat > "$BUNDLE/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>TrainYourPokemon</string>
  <key>CFBundleIdentifier</key><string>cl.franciscosoto.trainyourpokemon</string>
  <key>CFBundleName</key><string>Train Your Pokemon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- Menu bar only: no Dock icon, no app switcher entry. -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$BUNDLE" 2>/dev/null

echo "Built: $BUNDLE"
