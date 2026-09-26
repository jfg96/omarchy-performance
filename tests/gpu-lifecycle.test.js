const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const path = require('node:path')
const read = name => fs.readFileSync(path.join(__dirname, '..', name), 'utf8')
const Model = vm.runInNewContext(read('Model.js').replace(/^\.pragma library\s*\n/, '') +
  '\n({buildGpuSnapshot, buildGpuActivitySnapshot, mergeGpuActivity})')
const qml = read('Panel.qml')
// Exercise the actual controller functions with a deterministic clock and timer.
const functions = [...qml.matchAll(/^  function (\w+)\([^]*?^  }/gm)]
  .filter(match => /Gpu/.test(match[1]) || match[1] === "refresh").map(match => match[0]).join('\n')
let now = 1000
let warmups = 0
const ctx = vm.createContext({ Model, Date: { now: () => now }, opened: true,
  gpuCollector: { running: false }, gpuActivityCollector: { running: false },
  gpuWarmupTimer: { running: false, restart() { this.running = true; warmups++ },
    stop() { this.running = false } }, gpuIntervalMs: 4000, previousGpuActivityRaw: null,
  lastGpuActivityAt: 0, lastGpuSampleAt: 0, gpuActivity: [], gpuActivityWarming: true,
  gpuActivityError: '', gpuError: '', snapshot: { gpus: [] }, nowMs: now })
vm.runInContext(functions, ctx)
const activity = busy => `GPU_ACTIVITY\nGPUCLIENT\ti\t7\trender\t${busy}\t1\n`
const devices = 'GPU_SCAN\nGPU2\tn\tNVIDIA\tRTX\t23\t100\t800\t47\nGPU2\ti\tIntel\tUHD\t-\t-\t-\t51\n'
ctx.refreshGpu()
assert.equal(ctx.gpuCollector.running, true)
assert.equal(ctx.gpuActivityCollector.running, true)
assert.equal(ctx.applyGpuSample(devices), true)
let cards = Model.mergeGpuActivity(ctx.snapshot.gpus, [], 'loading', true)
assert.equal(cards[0].usage, 23)
assert.equal(cards[1].temperature, 51)
assert.equal(cards[1].usage, null)
assert.equal(cards[1].usageSource, 'pending')
ctx.applyGpuActivitySample(activity(1000000000))
assert.equal(warmups, 1)
ctx.gpuWarmupTimer.running = false
now += 400
ctx.applyGpuActivitySample(activity(1100000000))
cards = Model.mergeGpuActivity(ctx.snapshot.gpus, ctx.gpuActivity, 'current', ctx.gpuActivityWarming)
assert.equal(cards[1].usage, 25, 'warm-up uses real elapsed time')
assert.equal(warmups, 1, 'second sample does not rearm warm-up')
ctx.failGpuActivity('GPU sample timed out')
cards = Model.mergeGpuActivity(ctx.snapshot.gpus, ctx.gpuActivity, 'error', ctx.gpuActivityWarming)
assert.equal(cards[0].usage, 23)
assert.equal(cards[0].temperature, 47)
assert.equal(cards[1].usage, null)
assert.equal(ctx.gpuError, '', 'activity timeout does not poison device freshness')
ctx.opened = false
ctx.gpuActivityCollector.running = false
ctx.gpuCollector.running = false
ctx.refreshGpu()
ctx.refreshGpuActivity()
assert.equal(ctx.gpuActivityCollector.running, false)
assert.equal(ctx.gpuCollector.running, false)
ctx.applyGpuActivitySample(activity(1200000000))
assert.equal(warmups, 1, 'in-flight completion while closed cannot start timer')
ctx.opened = true
now += 13000
ctx.refreshGpuActivity()
assert.equal(ctx.previousGpuActivityRaw, null)
ctx.applyGpuActivitySample(activity(1500000000))
assert.equal(warmups, 2, 'stale reopening warms up again')
assert.equal(ctx.gpuActivity[0].usage, null)
assert.equal(ctx.applyGpuActivitySample('garbage'), false)
const openHandler = qml.match(/^  onOpenedChanged: ([\s\S]*?)^  BarIconButton/m)[1]
ctx.Qt = { callLater() {} }
ctx.refreshSystem = () => {}
vm.runInContext('function openedChanged() { ' + openHandler + ' }', ctx)
ctx.opened = false
ctx.openedChanged()
assert.equal(ctx.gpuWarmupTimer.running, false, 'closing cancels warm-up')
ctx.gpuActivityCollector.running = false
ctx.opened = true
ctx.openedChanged()
assert.equal(ctx.previousGpuActivityRaw, null, 'short reopen after cancelled warm-up resets baseline')
ctx.applyGpuActivitySample(activity(1600000000))
assert.equal(warmups, 3)
const stale = Model.mergeGpuActivity(ctx.snapshot.gpus, cards, 'stale', false)
assert.equal(stale[1].usage, null, 'stale activity is not displayed as live')
console.log('GPU lifecycle tests passed')
