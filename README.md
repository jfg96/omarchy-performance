# Omarchy Performance

A native Omarchy/Quickshell bar widget for lightweight system performance monitoring.

It keeps the closed-state polling cheap, expands telemetry while the panel is open,
and uses Linux `/proc` and `/sys` interfaces directly where practical.

## Screenshot

![Omarchy Performance panel showing system telemetry and top processes](assets/screenshots/performance-panel.png)

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
- GNU awk (`gawk`)
- Standard Linux procfs/sysfs utilities (`df`, `findmnt`, `getconf`, `readlink`)
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

## Sampling and reading the panel

Performance reads Linux `/proc` and `/sys` through `collect.sh`. With the panel
closed it takes a lightweight sample every 8 seconds. With the panel open it
samples every 1.5 seconds and also asks for GPU telemetry. CPU usage, process
CPU and disk read/write rates need two samples, so they initially show zero.
Memory and storage figures describe the most recent sample, not an average.

If collection fails, the panel keeps the last valid values but labels the
reading **out of date** and shows its age. Before any valid sample, it shows
**Data unavailable** instead of presenting zero as a measurement. A successful
sample clears the warning. A reading also becomes out of date when no new
sample arrives for three polling intervals (at least five seconds).

## Troubleshooting

- **Reading out of date / Data unavailable:** Run `./collect.sh --light` from
  the plugin directory. It should print a `SYSTEM` line followed by a `DISK`
  line. Check that the script is executable and that `gawk`, `findmnt` and
  `getconf` are available. The panel shows a brief collector error when it can.
- **No CPU temperature:** The CPU's `hwmon` driver may not expose a supported
  package temperature sensor. Performance leaves the value unavailable.
- **No GPU telemetry:** GPU collection runs only while the panel is open and
  currently requires `nvidia-smi` and an NVIDIA GPU. The first reported GPU is
  used on systems with several GPUs. AMD and Intel GPU telemetry is not
  supported.
- **No disk activity rate:** The root filesystem's block device may not map to
  readable `/sys/class/block/.../stat` counters. Storage capacity can still
  appear because it comes from `df`.

## Development checks

Run these from the repository root before proposing a runtime change:

```sh
bash -n collect.sh
node tests/model.test.js
node tests/collector.test.js
qmllint Panel.qml
```

The model tests use fixed samples; the collector test reads the machine running
it. CI runs the first three checks on Linux. `qmllint` checks QML syntax, but
neither it nor CI verifies the widget inside a live Omarchy/Quickshell session.

## License

MIT. See `LICENSE`.
