#!/usr/bin/env bash
set -euo pipefail

REPO="Joooooooooshua/AudioMatrixHub"
OS="$(uname -s)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

case "$OS" in
  Darwin)
    ASSET="AudioMatrixHub-v2.0.0-macOS-arm64.zip"
    URL="https://github.com/$REPO/releases/latest/download/$ASSET"
    echo "Downloading $ASSET..."
    curl -fsSL "$URL" -o "$TMP_DIR/$ASSET"
    ditto -x -k "$TMP_DIR/$ASSET" "$TMP_DIR/unpacked"
    bash "$TMP_DIR/unpacked/Install AudioMatrixHub.command"
    ;;
  Linux)
    ASSET="AudioMatrixHub-v2.0.0-Linux-x64.tar.gz"
    URL="https://github.com/$REPO/releases/latest/download/$ASSET"
    echo "Downloading $ASSET..."
    curl -fsSL "$URL" -o "$TMP_DIR/$ASSET"
    mkdir -p "$TMP_DIR/unpacked"
    tar -xzf "$TMP_DIR/$ASSET" -C "$TMP_DIR/unpacked"
    bash "$TMP_DIR/unpacked/install-linux.sh"
    ;;
  *)
    echo "Unsupported OS for install.sh: $OS"
    echo "For Windows, run: irm https://raw.githubusercontent.com/$REPO/main/scripts/install.ps1 | iex"
    exit 1
    ;;
esac
