# AudioMatrixHub

Lightweight desktop audio router, per-app mixer, and real-time spatial DSP control center for **macOS**, **Windows**, and **Linux**.

[English](README.md) · [简体中文](README.zh-CN.md) · [Releases](https://github.com/Joooooooooshua/AudioMatrixHub/releases/latest)

## Quick Install

### macOS (14.0+, Apple Silicon)

Run one command in Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/Joooooooooshua/AudioMatrixHub/main/scripts/install.sh | bash
```

Or download `AudioMatrixHub-v2.0.0-macOS-arm64.zip` from [Releases](https://github.com/Joooooooooshua/AudioMatrixHub/releases/latest), unzip it, and double-click **`Install AudioMatrixHub.command`** (strips Gatekeeper quarantine, installs `/Applications/AudioMatrixHub.app`, links the `audiomatrix` CLI, and launches the app).

### Windows (10 / 11 x64)

Run one command in PowerShell:

```powershell
irm https://raw.githubusercontent.com/Joooooooooshua/AudioMatrixHub/main/scripts/install.ps1 | iex
```

Or download `AudioMatrixHub-v2.0.0-Windows-x64.zip` from [Releases](https://github.com/Joooooooooshua/AudioMatrixHub/releases/latest), unzip it, and double-click **`Install-AudioMatrixHub.bat`** (installs `audiomatrix-desktop.exe` and `audiomatrix-pc.exe`, creates Desktop/Start Menu shortcuts, updates `PATH`, and launches).

### Linux (PipeWire / PulseAudio x64)

```bash
curl -fsSL https://raw.githubusercontent.com/Joooooooooshua/AudioMatrixHub/main/scripts/install.sh | bash
```

## What It Does

- **Decoupled I/O & BT Mic Guard**: Switch DACs, speakers, and Bluetooth headphones from one menu without letting macOS or Windows silently hijack your mic to low-bitrate telephony profiles.
- **Built-in Spatial & Tone DSP**: Independent Speaker Simulation (`Nearfield`, `Studio`, `Stage`) and Tone EQ (`Warm`, `Clear`, `Bass+`, `V-Shape`) with a fine-tuning panel (`Tune`) and soft-knee limiter. No third-party plugins needed.
- **Non-Destructive Per-App Mixer**: Adjust output-stage volume (`0%–200%`), mute, or re-route individual apps using CoreAudio Process Taps (macOS 14.2+), WASAPI `ISimpleAudioVolume` (Windows), or PipeWire `pactl` (Linux), with one-click `Reset to Default`.
- **Zero-Echo Loopback & WAV Recorder**: Mix mic and per-app system audio into a virtual input (`AudioMatrix Virtual Mic` on macOS needs no driver) or record directly to 48kHz Float32 `.wav` without headphone echo.
- **Share Audio**: Sync two physical outputs at once with independent volume sliders.
- **Optional VST3 / AU Chain**: Bridge into Kushview Element over UDP OSC (`9000`/`9001`) with live aggregate device hot-swapping (`<20ms`).

## Architecture

- **`rust-core/`**: Zero-dependency Rust C-ABI library handling the lock-free `AtomicU64` SPSC ring buffer, zero-alloc ITD/ILD/Haas/biquad DSP (`AmDspEngine`), WAV header encoding, OSC codec, and Windows WASAPI / Linux PipeWire OS drivers.
- **`Sources/`**: Native macOS SwiftUI menu bar app (`AudioMatrixHub.app`), CoreAudio HAL / `CATapDescription` pipeline, CLI (`audiomatrix`), and C FFI module (`CAudioMatrixRust`).
- **`rust-desktop/`**: Native `eframe` GUI (`audiomatrix-desktop`) and CLI (`audiomatrix-pc`) for Windows and Linux.

## Build from Source

```bash
# macOS (SwiftUI app + Rust core)
cargo build --release --manifest-path rust-core/Cargo.toml
swift build -c release
./scripts/bundle_app.sh
audiomatrix self-test

# Windows / Linux (Rust GUI + CLI)
cargo build --release --manifest-path rust-desktop/Cargo.toml
./rust-desktop/target/release/audiomatrix-pc self-test
```

## License

MIT
