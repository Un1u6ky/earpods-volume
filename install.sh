#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

LABEL="com.earpods-volume"
APP_DIR="$HOME/Library/Application Support/EarPodsVolume"
BIN="$APP_DIR/EarPodsVolume"
AGENTS="$HOME/Library/LaunchAgents"
PLIST="$AGENTS/$LABEL.plist"
UID_NUM="$(id -u)"

swiftc -parse-as-library -warnings-as-errors -O -o "$ROOT/EarPodsVolume" "$ROOT/main.swift"
mkdir -p "$APP_DIR" "$AGENTS"
cp -f "$ROOT/EarPodsVolume" "$BIN"
codesign -s - --force "$BIN"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${BIN}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
</dict>
</plist>
EOF

launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/${UID_NUM}" "$PLIST"
launchctl enable "gui/${UID_NUM}/${LABEL}" || true
launchctl kickstart -k "gui/${UID_NUM}/${LABEL}"

echo "Installed ${BIN}"
echo "LaunchAgent ${PLIST}"
