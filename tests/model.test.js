const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

// QML's .pragma library is not JavaScript syntax in Node. Evaluate the same
// source after removing only that directive, without adding test-only exports.
const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
const model = vm.runInNewContext(source.replace(/^\.pragma library\s*\n/, "") +
  "\n({ buildSnapshot, sampleState, topProcesses, gpuDetail, status })")

function sample(total, idle, uptime, processes = [], diskRead = 0) {
  return [
    `SYSTEM\t${total}\t${idle}\t1000\t500\t${uptime}\t45000\t4\t4096`,
    `DISK\t/\t10000\t2000\t8000\t${diskRead}\t0`,
    ...processes.map(p => `PROC\t${p.pid}\t${p.name}\t${p.ticks}\t${p.start}\t${p.rss}`)
  ].join("\n")
}

const first = model.buildSnapshot(sample(1000, 700, 10, [
  { pid: 12, name: "worker", ticks: 20, start: "100", rss: 10 }
], 100), null)
assert.ok(first)
assert.equal(first.cpu, 0, "the first reading has no CPU delta")
assert.equal(first.memoryPercent, 50)
assert.equal(first.temperature, 45)

const second = model.buildSnapshot(sample(1100, 750, 12, [
  { pid: 12, name: "worker", ticks: 30, start: "100", rss: 20 },
  { pid: 13, name: "new", ticks: 5, start: "105", rss: 5 }
], 120), first.raw)
assert.equal(second.cpu, 50)
assert.equal(second.disk.readRate, 5120)
assert.equal(second.processes[0].cpuTotalPercent, 10)
assert.equal(second.processes[0].cpuEquivalent, 0.4)
assert.equal(second.processes[1].cpuEquivalent, 0, "a new process has no previous delta")
assert.equal(model.topProcesses(second.processes, "memory", 1)[0].pid, 12)

const reusedPid = model.buildSnapshot(sample(1200, 800, 14, [
  { pid: 12, name: "replacement", ticks: 80, start: "200", rss: 5 }
], 90), second.raw)
assert.equal(reusedPid.processes[0].cpuEquivalent, 0, "PID reuse must not inherit CPU time")
assert.equal(reusedPid.disk.readRate, 0, "reset disk counters must not produce a negative rate")

const reset = model.buildSnapshot(sample(100, 70, 1), second.raw)
assert.equal(reset.cpu, 0, "reset CPU counters must not create a negative percentage")
assert.equal(model.buildSnapshot("", second.raw), null)
assert.equal(model.buildSnapshot("SYSTEM\t1\t0\t0\t0\t0\t0\t4\t4096", second.raw), null)

assert.equal(model.sampleState(0, 1000, 1500, false), "loading")
assert.equal(model.sampleState(0, 1000, 1500, true), "error")
assert.equal(model.sampleState(1000, 5999, 1500, false), "current")
assert.equal(model.sampleState(1000, 6001, 1500, false), "stale")
assert.equal(model.sampleState(1000, 9000, 8000, false), "current")
assert.equal(model.sampleState(1000, 2000, 1500, true), "stale")

const gpuBase = sample(1000, 700, 10) +
  "\nGPU2\t0000:00:02.0\tIntel\tIntegrated GPU\t-\t-\t-\t-" +
  "\nGPU2\t0000:03:00.0\tAMD\tDiscrete GPU\t72\t1073741824\t4294967296\t91" +
  "\nGPUCLIENT\t0000:00:02.0\t7\trender\t1000000000\t1"
const gpuNext = sample(1100, 750, 12) +
  "\nGPU2\t0000:00:02.0\tIntel\tIntegrated GPU\t-\t-\t-\t-" +
  "\nGPU2\t0000:03:00.0\tAMD\tDiscrete GPU\t72\t1073741824\t4294967296\t91" +
  "\nGPUCLIENT\t0000:00:02.0\t7\trender\t2000000000\t1" +
  "\nGPUCLIENT\t0000:00:02.0\t8\trender\t9999999999\t1"
const gpuFirst = model.buildSnapshot(gpuBase, null)
assert.equal(gpuFirst.gpus.length, 2)
assert.equal(gpuFirst.gpus[0].usage, null, "client activity needs a prior sample")
const gpuSecond = model.buildSnapshot(gpuNext, gpuFirst.raw)
assert.equal(gpuSecond.gpus[0].usage, 50)
assert.equal(gpuSecond.gpus[0].usageSource, "clients")
assert.equal(gpuSecond.gpus[1].usage, 72)
assert.equal(gpuSecond.gpus[1].usageSource, "device")
assert.match(model.gpuDetail(gpuSecond.gpus[0]), /Visible apps/)
assert.match(model.gpuDetail(gpuSecond.gpus[1]), /1.0 GiB \/ 4.0 GiB VRAM/)
assert.equal(model.status(0, 0, -1, gpuSecond.gpus, null).gpuTemperatureCritical, true)

const gpuReset = model.buildSnapshot(sample(1200, 800, 14) +
  "\nGPU2\t0000:00:02.0\tIntel\tIntegrated GPU\t-\t-\t-\t-" +
  "\nGPUCLIENT\t0000:00:02.0\t7\trender\t1\t1", gpuSecond.raw)
assert.equal(gpuReset.gpus[0].usage, null, "reset client counters must not create activity")

console.log("Model tests passed")
