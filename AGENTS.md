# Repository guidance

These instructions apply to this repository. Keep changes small, preserve
existing user settings, and check the current branch and diff before editing.
Read `README.md` for supported behavior and `.github/workflows/ci.yml` for the
automated checks.

## Project layout

- `manifest.json` declares one Omarchy `bar-widget` entry point, `Panel.qml`,
  under the stable ID `oma.performance`. Omarchy manages installation, updates,
  settings and removal.
- `Panel.qml` owns the widget, popup, keyboard navigation, sample timing and
  collector process. Keep collection out of the QML view where practical.
- `Model.js` parses collector records and calculates rates, health and display
  values. It is a QML library; Node tests evaluate the same source after
  removing the QML-only `.pragma library` directive.
- `collect.sh` reads CPU, memory, root storage and processes from Linux
  interfaces. Its `--light` mode skips GPU work; `--full` calls
  `collect-gpu.sh` while the panel is open.
- `collect-gpu.sh` discovers PCI DRM cards, reads driver telemetry and emits
  `GPU_SCAN`, `GPU2` and `GPUCLIENT` records. The model derives client activity
  from consecutive samples. Keep producers and the parser in sync when changing
  this tab-separated protocol.

## Metric correctness

- A missing, unreadable or unsupported metric is unavailable, not zero. Keep
  partial GPU records visible and label their missing fields accurately.
- NVIDIA uses `nvidia-smi`; AMD uses `amdgpu` sysfs values. Intel and other GPUs
  may only expose readable DRM client busy counters. The card labels this as
  visible app activity: its percentage is the busiest observed engine across
  visible clients, not device-wide utilization.
  Deduplicate shared DRM descriptors by device and client ID.
- Keep GPU identities stable across samples and cards. A card can have no
  temperature or dedicated VRAM, and a machine can have several GPUs.
- CPU, process, disk-rate and DRM-client activity calculations need two valid
  samples. Handle new processes/clients, reused PIDs and reset counters without
  inventing a spike. Do not present an old sample as live after collection
  fails or stalls.
- Preserve cheap closed-panel polling. Avoid new mandatory packages, root
  privileges or long-running commands in the 1.5-second open-panel path.

## Validation and handoff

Choose tests for the changed behavior. For runtime changes, run from the
repository root:

```sh
bash -n collect.sh collect-gpu.sh
shellcheck collect.sh collect-gpu.sh
node tests/model.test.js
node tests/collector.test.js
node tests/gpu.test.js
qmllint Panel.qml
git diff --check
```

`tests/model.test.js` exercises calculations with fixed samples;
`tests/gpu.test.js` uses fake DRM, procfs and NVIDIA sources;
`tests/collector.test.js` reads the host's Linux interfaces. CI runs the shell
and Node checks. `qmllint` checks syntax but cannot verify a live Omarchy UI.
For UI or collector lifecycle changes, also smoke-test in Quickshell when
available and say explicitly if that was not done. Do not claim AMD hardware,
other GPUs, or GPU access permissions were verified by fixture tests alone.

Update `README.md` when changing supported metrics, dependencies, sampling or
troubleshooting behavior. Keep `CHANGELOG.md` current for user-visible changes.
Before handoff, inspect the final diff and report the checks that actually ran
and any hardware or live-session behavior still unverified.
