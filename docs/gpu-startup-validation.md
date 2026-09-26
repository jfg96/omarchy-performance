# GPU startup validation — 2026-09-26

Host: Intel Raptor Lake-S UHD Graphics and NVIDIA RTX 5070 Laptop GPU.

## Measurements

Wall-clock time measured with Python `time.monotonic()` around subprocesses.
The original collector was read from `main`; measurements were sequential.

| Collector | Three consecutive runs (ms) |
| --- | --- |
| Original combined collector | 2658, 146, 133 |
| New device collector | 70, 74, 74 |
| New activity collector | 24, 17, 24 |

Earlier runs also showed approximately 2.7 seconds for the combined/device
path, while isolated activity took approximately 30 ms. Driver power state
and caching were not controlled; these are observations, not a claim that
splitting the collector alone eliminates that cold-start cost. The data does
not support an aggressive rewrite of fdinfo traversal or a hardware cache.

The activity scan now skips parsing unrelated fdinfo lines, preserving all
readable descriptors and client deduplication. Device collection skips name
lookup when NVIDIA already supplied a name. Optional NVIDIA and PCI name
commands have inner timeouts, allowing sysfs discovery to survive slow calls.
A cold NVIDIA query may therefore initially show unavailable metrics and use
a generic name; subsequent normal samples retry it.

## Validation

- Bash syntax and ShellCheck 0.10.0 for all three collectors.
- Existing model, live system collector and GPU fixture tests.
- New controller tests evaluate actual Panel.qml functions with deterministic
  time: immediate collection, metadata before activity, 400 ms counter delta,
  one-shot warm-up, timeout isolation, close cancellation, short reopen and
  stale reopen. Stale activity never supplies a live percentage.
- GPU fixtures cover slow NVIDIA and PCI name commands without losing Intel
  metadata, plus existing shared-descriptor and engine-capacity behavior.
- `qmllint Panel.qml` and `git diff --check`.
- Standalone Quickshell smoke test imported the actual Panel.qml with the
  installed Omarchy UI components, opened and closed it, observed two device
  cards and Intel activity after warm-up, and finished without collector errors.

The installed plugin was not replaced. The standalone smoke test does not
verify anchoring or appearance in the user's actual bar. AMD and restricted
GPU access were covered by fixtures only, not physical hardware validation.
