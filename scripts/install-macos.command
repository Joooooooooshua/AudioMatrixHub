#!/bin/zsh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$SCRIPT_DIR/AudioMatrixHub.app"
CLI_SRC="$SCRIPT_DIR/audiomatrix"

if [ ! -d "$APP_SRC" ]; then
    echo "Error: AudioMatrixHub.app not found next to this installer."
    exit 1
fi

INSTALL_DIR="/Applications"
if [ ! -w "$INSTALL_DIR" ]; then
    INSTALL_DIR="$HOME/Applications"
    mkdir -p "$INSTALL_DIR"
fi
APP_DEST="$INSTALL_DIR/AudioMatrixHub.app"

echo "Installing AudioMatrixHub to $APP_DEST..."
killall AudioMatrixHub 2>/dev/null || true
sleep 0.5

rm -rf "$APP_DEST"
cp -R "$APP_SRC" "$APP_DEST"

if [ -f "$CLI_SRC" ]; then
    cp "$CLI_SRC" "$APP_DEST/Contents/MacOS/audiomatrix"
    chmod +x "$APP_DEST/Contents/MacOS/audiomatrix"
fi

# Strip quarantine attributes and ensure valid ad-hoc signature so macOS opens immediately
xattr -cr "$APP_DEST" 2>/dev/null || true
codesign --force --deep --sign - "$APP_DEST" 2>/dev/null || true

CLI_TARGET="$APP_DEST/Contents/MacOS/audiomatrix"
if [ -d "/opt/homebrew/bin" ] && [ -w "/opt/homebrew/bin" ]; then
    ln -sf "$CLI_TARGET" "/opt/homebrew/bin/audiomatrix"
elif [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
    ln -sf "$CLI_TARGET" "/usr/local/bin/audiomatrix"
else
    mkdir -p "$HOME/.local/bin"
    ln -sf "$CLI_TARGET" "$HOME/.local/bin/audiomatrix"
fi

# Optional BlackHole 2ch (only needed if routing external Kushview Element VST3/AU chains)
if [ -z "$CI" ] && [ -t 0 ] && command -v brew >/dev/null 2>&1 && [ ! -d "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver" ]; then
    echo ""
    echo "Note: Built-in AudioMatrix Virtual Mic requires zero drivers."
    printf "Install optional BlackHole 2ch for external Element VST3/AU chains? [y/N] "
    read -r reply
    if [[ "$reply" =~ ^[Yy]$ ]]; then
        brew install --cask blackhole-2ch || true
    fi
fi

echo "Done! Installed $APP_DEST and linked 'audiomatrix' CLI."
if [ -z "$CI" ]; then
    open -a "$APP_DEST"
fi
