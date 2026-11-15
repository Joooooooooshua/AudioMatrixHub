#!/bin/zsh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export PATH="$HOME/.cargo/bin:$PATH"

echo "Building Rust C-ABI Core (libaudiomatrix_rust_core.a)..."
cargo build --release --manifest-path "$PROJECT_DIR/rust-core/Cargo.toml"

if [ ! -f "$PROJECT_DIR/.build/release/AudioMatrixHub" ] || [ ! -f "$PROJECT_DIR/.build/release/audiomatrix" ]; then
    echo "Building SwiftUI & CLI release binaries..."
    (cd "$PROJECT_DIR" && swift build -c release)
fi

if [[ "$1" == "--install-deps" ]]; then
    if command -v brew >/dev/null 2>&1; then
        echo "Checking optional audio dependencies via Homebrew..."
        if [ ! -d "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver" ]; then
            brew install --cask blackhole-2ch
        fi
        if ! command -v SwitchAudioSource >/dev/null 2>&1; then
            brew install switchaudio-osx
        fi
    else
        echo "Homebrew not found; skipping --install-deps."
    fi
fi

APP_BUNDLE="/Applications/AudioMatrixHub.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$PROJECT_DIR/.build/release/AudioMatrixHub" "$MACOS_DIR/AudioMatrixHub"
chmod +x "$MACOS_DIR/AudioMatrixHub"

cp "$PROJECT_DIR/.build/release/audiomatrix" "$MACOS_DIR/audiomatrix"
chmod +x "$MACOS_DIR/audiomatrix"

cat > "$CONTENTS_DIR/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>AudioMatrixHub</string>
    <key>CFBundleIdentifier</key>
    <string>com.audiomatrix.AudioMatrixHub</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>AudioMatrixHub</string>
    <key>CFBundleDisplayName</key>
    <string>AudioMatrix Hub</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>AudioMatrixHub uses CoreAudio Process Tap to route individual application audio streams.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>AudioMatrixHub reads audio input device state to prevent Bluetooth microphone hijacking.</string>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true

# Link CLI tool into Homebrew bin if available
if [ -d "/opt/homebrew/bin" ]; then
    ln -sf "$PROJECT_DIR/.build/release/audiomatrix" "/opt/homebrew/bin/audiomatrix"
elif [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
    ln -sf "$PROJECT_DIR/.build/release/audiomatrix" "/usr/local/bin/audiomatrix"
fi

echo "Successfully bundled $APP_BUNDLE"
