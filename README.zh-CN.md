# AudioMatrixHub

跨 **macOS**、**Windows**、**Linux** 的轻量系统音频路由、分软件调音台与实时声场控制中心。

[English](README.md) · [简体中文](README.zh-CN.md) · [Releases 下载](https://github.com/Joooooooooshua/AudioMatrixHub/releases/latest)

## 一键安装

### macOS (14.0+, Apple Silicon)

终端运行一行命令即可自动下载、解除隔离并安装启动：

```bash
curl -fsSL https://raw.githubusercontent.com/Joooooooooshua/AudioMatrixHub/main/scripts/install.sh | bash
```

也可以去 [Releases](https://github.com/Joooooooooshua/AudioMatrixHub/releases/latest) 下载 `AudioMatrixHub-v2.0.0-macOS-arm64.zip`，解压后直接双击 **`Install AudioMatrixHub.command`**（会自动清除系统隔离标记、安装到 `/Applications/AudioMatrixHub.app`、配置 `audiomatrix` 命令行并启动）。

### Windows (10 / 11 x64)

PowerShell 运行一行命令：

```powershell
irm https://raw.githubusercontent.com/Joooooooooshua/AudioMatrixHub/main/scripts/install.ps1 | iex
```

或去 [Releases](https://github.com/Joooooooooshua/AudioMatrixHub/releases/latest) 下载 `AudioMatrixHub-v2.0.0-Windows-x64.zip`，解压后双击 **`Install-AudioMatrixHub.bat`**（自动释放权限、安装 `audiomatrix-desktop.exe` 与 `audiomatrix-pc.exe`、创建桌面与开始菜单快捷方式、加入 `PATH` 并打开界面）。

### Linux (PipeWire / PulseAudio x64)

```bash
curl -fsSL https://raw.githubusercontent.com/Joooooooooshua/AudioMatrixHub/main/scripts/install.sh | bash
```

## 核心功能

- **输入/输出解耦 + 蓝牙麦克风防劫持**：独立切换耳机/DAC 与麦克风，连蓝牙耳机时不会把系统输入切去低音质通话模式。
- **开箱即用内置 DSP**：内置独立的音箱声场模拟（`Nearfield` / `Studio` / `Stage`）和普适音色 EQ（`Warm` / `Clear` / `Bass+` / `V-Shape`），可协同开启并在 `Tune` 中微调。
- **输出侧分软件调音台**：基于 macOS `CATapDescription`、Windows WASAPI `ISimpleAudioVolume` 与 Linux `pactl` 在输出端独立调节每个应用音量（`0%–200%`）、静音与设备路由，带一键 `Reset to Default`。
- **0 回声旁路内录与 WAV 录音**：内置免驱动虚拟麦（`AudioMatrix Virtual Mic`），可独立混入麦克风与各应用声音做内录或导出 48kHz Float32 `.wav`，耳机监听无回声。
- **双人同听 (Share Audio)**：同时输出到两副耳机并分别调节音量。
- **可选 VST3 / AU 插件链**：通过 UDP OSC 桥接 Kushview Element，切换输出耳机 `<20ms` 热更新。

## 目录结构

- **`rust-core/`**：零依赖 Rust C-ABI 音频内核（无锁 SPSC 环形缓冲、零堆分配双耳 DSP 与渐变 EQ、WAV/OSC 编解码，以及 Windows WASAPI / Linux PipeWire 驱动实现）。
- **`Sources/`**：macOS 原生 SwiftUI 菜单栏控制中心（`AudioMatrixHub.app`）、CoreAudio HAL 与 CLI（`audiomatrix`）。
- **`rust-desktop/`**：Windows 与 Linux 端原生桌面窗口（`audiomatrix-desktop`）与 CLI（`audiomatrix-pc`）。

## 从源码构建

```bash
# macOS
cargo build --release --manifest-path rust-core/Cargo.toml
swift build -c release
./scripts/bundle_app.sh
audiomatrix self-test

# Windows / Linux
cargo build --release --manifest-path rust-desktop/Cargo.toml
./rust-desktop/target/release/audiomatrix-pc self-test
```

## 开源协议

MIT
