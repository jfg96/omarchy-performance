const assert = require("node:assert/strict")
const { execFileSync } = require("node:child_process")
const path = require("node:path")
const fs = require("node:fs")
const os = require("node:os")
const vm = require("node:vm")

const script = path.join(__dirname, "..", "collect.sh")
const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
const model = vm.runInNewContext(source.replace(/^\.pragma library\s*\n/, "") +
  "\n({ buildSnapshot })")

const output = execFileSync(script, [], { encoding: "utf8", timeout: 15000 })
assert.ok(output.startsWith("SYSTEM\t"), "system collector must emit a system record")
assert.ok(output.includes("\nDISK\t"), "system collector must emit a disk record")
const snapshot = model.buildSnapshot(output, null)
assert.ok(snapshot, "system output must be accepted by Model.js")
assert.ok(snapshot.memoryTotalBytes > 0)
assert.equal(snapshot.gpus.length, 0, "system collection must not wait for GPU telemetry")
assert.equal(snapshot.gpuScanned, false)

const fixture = fs.mkdtempSync(path.join(os.tmpdir(), "performance-system-only-"))
try {
  const marker = path.join(fixture, "gpu-invoked")
  const smi = path.join(fixture, "nvidia-smi")
  fs.writeFileSync(smi, `#!/bin/sh\ntouch '${marker}'\nexit 1\n`)
  fs.chmodSync(smi, 0o755)
  const isolated = execFileSync(script, [], {
    encoding: "utf8", timeout: 15000,
    env: { ...process.env, PERFORMANCE_NVIDIA_SMI: smi }
  })
  assert.ok(model.buildSnapshot(isolated, snapshot.raw), "GPU failure must not invalidate system sampling")
  assert.equal(fs.existsSync(marker), false, "system collection must not invoke GPU commands")
} finally {
  fs.rmSync(fixture, { recursive: true, force: true })
}

console.log("Collector tests passed")
