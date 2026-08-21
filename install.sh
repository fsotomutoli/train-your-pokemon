#!/bin/bash
# Installs Train Your Pokemon as a login item and starts it.
#
# The LaunchAgent needs an absolute path to the built binary, so the plist is
# generated here from wherever the repo happens to live rather than shipped
# with a hardcoded one.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$REPO_DIR/app/TrainYourPokemon.app/Contents/MacOS/TrainYourPokemon"
LABEL="dev.trainyourpokemon.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ ! -x "$BINARY" ]; then
    echo "The app is not built yet. Run: bash app/build.sh" >&2
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>

  <key>ProgramArguments</key>
  <array>
    <string>$BINARY</string>
  </array>

  <!-- Starts once when the user logs in. -->
  <key>RunAtLoad</key>
  <true/>

  <!-- Deliberately NOT KeepAlive: the panel has a Quit button, and KeepAlive
       would relaunch the app the moment the user closes it. -->
  <key>KeepAlive</key>
  <false/>

  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
EOF

plutil -lint "$PLIST" > /dev/null

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "Installed. Look for your Pokemon in the menu bar."
echo "macOS will ask for notification permission on first launch — allow it to"
echo "get evolution banners."
echo
echo "To uninstall:  launchctl unload \"$PLIST\" && rm \"$PLIST\""
