const assert = require("node:assert/strict")
const { execFileSync } = require("node:child_process")
const path = require("node:path")
const fs = require("node:fs")
const vm = require("node:vm")

const script = path.join(__dirname, "..", "collect.sh")
const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
const model = vm.runInNewContext(source.replace(/^\.pragma library\s*\n/, "") +
  "\n({ buildSnapshot })")

for (const mode of ["--light", "--full"]) {
  const output = execFileSync(script, [mode], { encoding: "utf8", timeout: 15000 })
  assert.ok(output.startsWith("SYSTEM\t"), `${mode} must emit a system record`)
  assert.ok(output.includes("\nDISK\t"), `${mode} must emit a disk record`)
  const snapshot = model.buildSnapshot(output, null)
  assert.ok(snapshot, `${mode} output must be accepted by Model.js`)
  assert.ok(snapshot.memoryTotalBytes > 0)
  if (mode === "--light") {
    assert.equal(snapshot.gpus.length, 0, "light polling must skip GPU telemetry")
    assert.equal(snapshot.gpuScanned, false)
  } else assert.equal(snapshot.gpuScanned, true)
}

console.log("Collector tests passed")
