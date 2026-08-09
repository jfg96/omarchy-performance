# Omarchy Performance

A native Omarchy/Quickshell bar widget for lightweight system performance monitoring.

It keeps the closed-state polling cheap, expands telemetry while the panel is open,
and uses Linux `/proc` and `/sys` interfaces directly where practical.

## Features

- Global CPU usage and logical CPU count
- CPU package temperature when exposed through `hwmon`
- Used/total memory based on `MemAvailable`
- Root filesystem usage and block-device read/write activity
- NVIDIA GPU utilization, VRAM and temperature when `nvidia-smi` is available
- Top five processes by CPU or memory
- Process CPU shown as both total system share and logical-CPU equivalents (`CPU×`)
- Keyboard and mouse navigation
- One-click launch of `btop`
- Adaptive polling: lightweight while closed, fuller sampling while open

## Requirements

- Omarchy with the Quickshell-based shell/plugin system
- Bash
- Standard Linux procfs/sysfs utilities (`awk`, `df`, `findmnt`, `getconf`, `readlink`)
- `btop` for the action button
- Optional: `nvidia-smi` for NVIDIA telemetry

## Install

Install and enable the widget with Omarchy's plugin manager:

```sh
omarchy plugin add https://github.com/jfg96/omarchy-performance.git --enable
```

The widget is placed in the right section of the bar by default. Omarchy manages
updates and removal with `omarchy plugin update oma.performance` and
`omarchy plugin remove oma.performance`.

The plugin lives entirely in the user's Omarchy configuration and does not modify
`/usr/share/omarchy`.

## CPU semantics

Process CPU is displayed as `TOTAL | CPU×`:

- `TOTAL` is the process share of the machine's total logical CPU capacity.
- `CPU×` is the equivalent number of fully utilized logical CPUs.

For example, `1.00×` means one logical CPU fully utilized and `2.00×` means the
equivalent of two logical CPUs fully utilized.

## Notes

GPU telemetry is intentionally collected only in the fuller/open-panel sample path.
Unsupported or unavailable sensors are omitted rather than treated as errors.

GPU telemetry is currently designed specifically for NVIDIA graphics cards through
`nvidia-smi`. AMD and Intel GPU telemetry is not supported. Support for other GPU
vendors may be considered in the future, but it is not currently planned or
guaranteed.

## License

MIT. See `LICENSE`.
