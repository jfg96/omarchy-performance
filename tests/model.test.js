const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

// QML's .pragma library is not JavaScript syntax in Node. Evaluate the same
// source after removing only that directive, without adding test-only exports.
const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
const model = vm.runInNewContext(source.replace(/^\.pragma library\s*\n/, "") +
  "\n({ buildSnapshot, sampleState, topProcesses, gpuDetail, gpuName, gpuTooltip, orderGpus, status })")

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

const vanished = model.buildSnapshot(sample(1150, 775, 13, [
  { pid: 13, name: "new", ticks: 9, start: "105", rss: 5 }
]), second.raw)
assert.deepEqual(Array.from(model.topProcesses(vanished.processes, "memory", 5).map(p => p.pid)), [13],
  "a process absent from the next sample must disappear from memory ranking")
const memoryTies = model.buildSnapshot(sample(1200, 800, 14, [
  { pid: 30, name: "larger", ticks: 0, start: "300", rss: 30 },
  { pid: 22, name: "tie", ticks: 0, start: "220", rss: 20 },
  { pid: 21, name: "tie", ticks: 0, start: "210", rss: 20 }
]), vanished.raw)
assert.deepEqual(Array.from(model.topProcesses(memoryTies.processes, "memory", 5).map(p => p.pid)),
  [30, 21, 22], "memory ranking uses RSS descending and PID to break ties")

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
assert.equal(gpuFirst.gpus[1].usage, null, "client activity needs a prior sample")
const gpuSecond = model.buildSnapshot(gpuNext, gpuFirst.raw)
assert.equal(gpuSecond.gpus[0].vendor, "AMD", "discrete GPUs precede integrated GPUs")
assert.equal(gpuSecond.gpus[1].usage, 50)
assert.equal(gpuSecond.gpus[1].usageSource, "clients")
assert.equal(gpuSecond.gpus[0].usage, 72)
assert.equal(gpuSecond.gpus[0].usageSource, "device")
assert.equal(model.gpuDetail(gpuSecond.gpus[1]), "Visible app activity")
assert.match(model.gpuTooltip(gpuSecond.gpus[1]), /not total GPU utilization/)
assert.match(model.gpuDetail(gpuSecond.gpus[0]), /1.0 GiB \/ 4.0 GiB VRAM/)
assert.equal(model.status(0, 0, -1, gpuSecond.gpus, null).gpuTemperatureCritical, true)

const gpuReset = model.buildSnapshot(sample(1200, 800, 14) +
  "\nGPU2\t0000:00:02.0\tIntel\tIntegrated GPU\t-\t-\t-\t-" +
  "\nGPUCLIENT\t0000:00:02.0\t7\trender\t1\t1", gpuSecond.raw)
assert.equal(gpuReset.gpus[0].usage, null, "reset client counters must not create activity")
assert.equal(gpuReset.raw.gpuClients[0].busyNs, 2000000000,
  "a temporary regression keeps the last high-water mark")
const gpuRecovered = model.buildSnapshot(sample(1300, 850, 16) +
  "\nGPU2\t0000:00:02.0\tIntel\tIntegrated GPU\t-\t-\t-\t-" +
  "\nGPUCLIENT\t0000:00:02.0\t7\trender\t2200000000\t1", gpuReset.raw)
assert.equal(gpuRecovered.gpus[0].usage, 10)

const gpuJump = model.buildSnapshot(sample(1400, 900, 18) +
  "\nGPU2\t0000:00:02.0\tIntel\tIntegrated GPU\t-\t-\t-\t-" +
  "\nGPUCLIENT\t0000:00:02.0\t7\trender\t99999999999\t1", gpuRecovered.raw)
assert.equal(gpuJump.gpus[0].usage, null, "implausible jumps must not show as 100% activity")

const multiBase = sample(1000, 700, 10) +
  "\nGPU2\t0000:00:02.0\tIntel\tIntel Corporation Raptor Lake-S UHD Graphics\t-\t-\t-\t-" +
  "\nGPUCLIENT\t0000:00:02.0\t1\trender\t1000000000\t1" +
  "\nGPUCLIENT\t0000:00:02.0\t2\trender\t1000000000\t1" +
  "\nGPUCLIENT\t0000:00:02.0\t1\tvideo\t1000000000\t2"
const multiNext = sample(1100, 750, 12) +
  "\nGPU2\t0000:00:02.0\tIntel\tIntel Corporation Raptor Lake-S UHD Graphics\t-\t-\t-\t-" +
  "\nGPUCLIENT\t0000:00:02.0\t1\trender\t1500000000\t1" +
  "\nGPUCLIENT\t0000:00:02.0\t1\trender\t1500000000\t1" +
  "\nGPUCLIENT\t0000:00:02.0\t2\trender\t1500000000\t1" +
  "\nGPUCLIENT\t0000:00:02.0\t1\tvideo\t3000000000\t2" +
  "\nGPUCLIENT\t0000:00:02.0\t3\trender\t9000000000\t1"
const multiFirst = model.buildSnapshot(multiBase, null)
const multiSecond = model.buildSnapshot(multiNext, multiFirst.raw)
assert.equal(multiSecond.raw.gpuClients.length, 4, "duplicate client records are counted once")
assert.equal(multiSecond.gpus[0].usage, 50,
  "two render clients add to 50%, and a two-engine video group also reaches 50%")
assert.equal(model.gpuName(multiSecond.gpus[0]), "Intel UHD Graphics")
assert.equal(model.gpuName({vendor:"NVIDIA",name:"NVIDIA GeForce RTX 5070 Laptop GPU"}), "GeForce RTX 5070")
assert.equal(model.gpuName({vendor:"AMD",name:"Advanced Micro Devices, Inc. [AMD/ATI] Radeon RX 7900"}), "Radeon RX 7900")
assert.equal(model.gpuName({vendor:"Other",name:"Unfamiliar Device"}), "Unfamiliar Device")
assert.deepEqual(Array.from(model.orderGpus([
  {id:"0000:00:02.0",vendor:"Intel",memoryTotalBytes:null},
  {id:"0000:05:00.0",vendor:"Other",memoryTotalBytes:null},
  {id:"0000:04:00.0",vendor:"AMD",memoryTotalBytes:4096},
  {id:"0000:01:00.0",vendor:"NVIDIA",memoryTotalBytes:8192}
]).map(gpu => gpu.id)), ["0000:01:00.0", "0000:04:00.0", "0000:00:02.0", "0000:05:00.0"])
assert.equal(model.gpuDetail({usage:null,usageSource:"unavailable",memoryUsedBytes:null,memoryTotalBytes:null,temperature:null}),
  "Usage unavailable", "missing optional metrics should not crowd the card")

const removed = model.buildSnapshot(sample(1200, 800, 14) +
  "\nGPU2\t0000:00:02.0\tIntel\tIntel GPU\t-\t-\t-\t-" +
  "\nGPUCLIENT\t0000:00:02.0\t4\trender\t5000000000\t1", multiSecond.raw)
assert.equal(removed.gpus[0].usage, null, "disappeared and new clients provide no comparable delta")

console.log("Model tests passed")
