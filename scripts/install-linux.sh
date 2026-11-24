#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/applications"

mkdir -p "$BIN_DIR" "$APP_DIR"
cp "$SCRIPT_DIR/audiomatrix-desktop" "$BIN_DIR/audiomatrix-desktop"
cp "$SCRIPT_DIR/audiomatrix-pc" "$BIN_DIR/audiomatrix-pc"
chmod +x "$BIN_DIR/audiomatrix-desktop" "$BIN_DIR/audiomatrix-pc"

cat > "$APP_DIR/audiomatrix-hub.desktop" << EOF
[Desktop Entry]
Type=Application
Name=AudioMatrixHub
Comment=PipeWire audio routing, spatial DSP, and per-app mixer
Exec=$BIN_DIR/audiomatrix-desktop
Icon=audio-card
Terminal=false
Categories=AudioVideo;Audio;Mixer;
EOF

if ! command -v pactl >/dev/null 2>&1; then
    echo "Warning: 'pactl' not found. Install pipewire-pulse or pulseaudio-utils for live audio routing."
fi

echo "Installed to $BIN_DIR and registered desktop launcher in $APP_DIR/audiomatrix-hub.desktop"
