# Changelog

## 1.1.0

- Detect multiple NVIDIA, AMD and Intel GPUs, with device metrics or visible
  client activity where the kernel and driver expose them.
- Present GPUs in a compact adaptive grid with concise names, stable ordering
  and clear labels for direct versus visible-client activity.
- Preserve DRM counter high-water marks and reject implausible activity jumps.
- Show collector failures and identify readings that have stopped updating.
- Add model and collector checks, plus ShellCheck in Linux CI.
- Document sampling, unavailable sensors and basic troubleshooting.
- Make the full activity monitor action optional when `btop` is absent.

## 1.0.0

- Initial public release.
- Adaptive lightweight/full telemetry sampling.
- CPU, memory, temperature, storage, optional NVIDIA GPU telemetry and process view.
