const assert = require("node:assert/strict")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const { execFileSync } = require("node:child_process")
const vm = require("node:vm")

const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
const model = vm.runInNewContext(source.replace(/^\.pragma library\s*\n/, "") +
  "\n({ buildSnapshot })")
const fixture = fs.mkdtempSync(path.join(os.tmpdir(), "performance-gpu-"))
const drm = path.join(fixture, "drm")
const devices = path.join(fixture, "devices")
const proc = path.join(fixture, "proc")
fs.mkdirSync(drm)
fs.mkdirSync(devices)
fs.mkdirSync(proc)

function card(index, bdf, vendor, files = {}) {
  const device = path.join(devices, bdf)
  fs.mkdirSync(device)
  fs.writeFileSync(path.join(device, "vendor"), vendor + "\n")
  for (const [name, value] of Object.entries(files))
    fs.writeFileSync(path.join(device, name), value + "\n")
  const cardDir = path.join(drm, "card" + index)
  fs.mkdirSync(cardDir)
  fs.symlinkSync(device, path.join(cardDir, "device"))
  return device
}

try {
  const intel = card(0, "0000:00:02.0", "0x8086")
  const intelHwmon = path.join(intel, "hwmon", "hwmon0")
  fs.mkdirSync(intelHwmon, { recursive: true })
  fs.writeFileSync(path.join(intelHwmon, "temp1_input"), "55000\n")
  card(1, "0000:01:00.0", "0x10de")
  const amd = card(2, "0000:03:00.0", "0x1002", {
    product_name: "Radeon Test", gpu_busy_percent: "48",
    mem_info_vram_used: "1073741824", mem_info_vram_total: "4294967296"
  })
  const amdHwmon = path.join(amd, "hwmon", "hwmon1")
  fs.mkdirSync(amdHwmon, { recursive: true })
  fs.writeFileSync(path.join(amdHwmon, "temp1_input"), "67000\n")

  const smi = path.join(fixture, "nvidia-smi")
  fs.writeFileSync(smi, "#!/bin/sh\nprintf '%s\\n' '00000000:01:00.0, RTX Test, 23, 100, 8000, 47' '00000000:04:00.0, Compute Test, N/A, 0, 16000, N/A'\n")
  fs.chmodSync(smi, 0o755)

  for (const pid of [100, 101]) {
    const fdinfo = path.join(proc, String(pid), "fdinfo")
    fs.mkdirSync(fdinfo, { recursive: true })
    fs.writeFileSync(path.join(fdinfo, "3"),
      "drm-driver:\ti915\ndrm-pdev:\t0000:00:02.0\ndrm-client-id:\t7\n" +
      "drm-engine-render:\t1000000000 ns\ndrm-engine-capacity-render:\t2\n")
  }

  const output = execFileSync(path.join(__dirname, "..", "collect-gpu.sh"), [], {
    encoding: "utf8",
    env: { ...process.env, PERFORMANCE_DRM_ROOT: drm, PERFORMANCE_PROC_ROOT: proc,
      PERFORMANCE_NVIDIA_SMI: smi }
  })
  const snapshot = model.buildSnapshot(
    "SYSTEM\t100\t50\t1000\t500\t1\t0\t4\t4096\n" + output, null)
  assert.ok(snapshot)
  assert.equal(snapshot.gpuScanned, true)
  assert.equal(snapshot.gpus.length, 4, "DRM cards and a compute-only NVIDIA GPU are included once")
  const byId = Object.fromEntries(snapshot.gpus.map(gpu => [gpu.id, gpu]))
  assert.equal(byId["0000:00:02.0"].vendor, "Intel")
  assert.equal(byId["0000:00:02.0"].temperature, 55)
  assert.equal(byId["0000:01:00.0"].usage, 23)
  assert.equal(byId["0000:01:00.0"].memoryTotalBytes, 8000 * 1048576)
  assert.equal(byId["0000:03:00.0"].name, "Radeon Test")
  assert.equal(byId["0000:03:00.0"].usage, 48)
  assert.equal(byId["0000:03:00.0"].temperature, 67)
  assert.equal(byId["0000:04:00.0"].usage, null, "unsupported utilization stays unavailable")
  assert.equal(snapshot.raw.gpuClients.length, 1, "shared DRM client descriptors are counted once")
  assert.equal(snapshot.raw.gpuClients[0].capacity, 2)

  for (const pid of [100, 101])
    fs.writeFileSync(path.join(proc, String(pid), "fdinfo", "3"),
      "drm-driver:\ti915\ndrm-pdev:\t0000:00:02.0\ndrm-client-id:\t7\n" +
      "drm-engine-render:\t3000000000 ns\ndrm-engine-capacity-render:\t2\n")
  const nextOutput = execFileSync(path.join(__dirname, "..", "collect-gpu.sh"), [], {
    encoding: "utf8",
    env: { ...process.env, PERFORMANCE_DRM_ROOT: drm, PERFORMANCE_PROC_ROOT: proc,
      PERFORMANCE_NVIDIA_SMI: smi }
  })
  const next = model.buildSnapshot(
    "SYSTEM\t200\t100\t1000\t500\t3\t0\t4\t4096\n" + nextOutput, snapshot.raw)
  assert.equal(next.gpus.find(gpu => gpu.vendor === "Intel").usage, 50,
    "two real collector samples normalize client busy time by engine capacity")

  const noLspci = execFileSync(path.join(__dirname, "..", "collect-gpu.sh"), [], {
    encoding: "utf8",
    env: { ...process.env, PERFORMANCE_DRM_ROOT: drm, PERFORMANCE_PROC_ROOT: proc,
      PERFORMANCE_NVIDIA_SMI: smi, PERFORMANCE_LSPCI: path.join(fixture, "missing-lspci") }
  })
  const fallback = model.buildSnapshot(
    "SYSTEM\t200\t100\t1000\t500\t3\t0\t4\t4096\n" + noLspci, null)
  assert.equal(fallback.gpus.find(gpu => gpu.vendor === "Intel").name, "Intel GPU")
} finally {
  fs.rmSync(fixture, { recursive: true, force: true })
}

console.log("GPU collector tests passed")
