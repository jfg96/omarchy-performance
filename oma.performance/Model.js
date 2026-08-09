.pragma library

var THRESHOLDS = {
  cpu: { warning: 80, critical: 95 },
  cpuTemperature: { warning: 85, critical: 95 },
  memory: { warning: 85, critical: 95 },
  gpuTemperature: { warning: 82, critical: 90 },
  storage: { warning: 90, critical: 97 }
}

function number(value, fallback) {
  var parsed = Number(value)
  return isFinite(parsed) ? parsed : (fallback === undefined ? 0 : fallback)
}

function clamp(value, low, high) {
  return Math.max(low, Math.min(high, value))
}

function parse(raw) {
  var result = { system: {}, disk: null, gpu: null, processes: [], validSystem: false }
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t")
    if (parts[0] === "SYSTEM" && parts.length >= 9) {
      result.system = {
        total: number(parts[1]), idle: number(parts[2]), memTotalKb: number(parts[3]),
        memAvailableKb: number(parts[4]), uptime: number(parts[5]),
        tempMilli: number(parts[6]), cpuCount: Math.max(1, number(parts[7], 1)),
        pageSize: Math.max(1, number(parts[8], 4096))
      }
      result.validSystem = isFinite(Number(parts[1])) && isFinite(Number(parts[2]))
        && isFinite(Number(parts[3])) && Number(parts[3]) > 0
        && isFinite(Number(parts[4])) && Number(parts[4]) >= 0
        && isFinite(Number(parts[5])) && Number(parts[5]) >= 0
        && isFinite(Number(parts[6]))
        && isFinite(Number(parts[7])) && Number(parts[7]) >= 1
        && isFinite(Number(parts[8])) && Number(parts[8]) >= 1
    } else if (parts[0] === "DISK") {
      result.disk = {
        mount: parts[1], total: number(parts[2]), used: number(parts[3]), available: number(parts[4]),
        readSectors: number(parts[5]), writeSectors: number(parts[6])
      }
    } else if (parts[0] === "GPU") {
      result.gpu = {
        name: parts[1], usage: number(parts[2]), memoryUsedMb: number(parts[3]),
        memoryTotalMb: number(parts[4]), temperature: number(parts[5])
      }
    } else if (parts[0] === "PROC" && parts.length >= 6) {
      result.processes.push({
        pid: number(parts[1]), name: parts[2], ticks: number(parts[3]),
        starttime: parts[4], rssPages: number(parts[5])
      })
    }
  }
  return result
}

function buildSnapshot(raw, previous) {
  var current = parse(raw)
  if (!current.validSystem) return null
  var system = current.system
  var totalDelta = previous && previous.system ? system.total - previous.system.total : 0
  var idleDelta = previous && previous.system ? system.idle - previous.system.idle : 0
  var cpuPercent = totalDelta > 0 ? clamp((totalDelta - idleDelta) * 100 / totalDelta, 0, 100) : 0
  var memoryUsedKb = Math.max(0, system.memTotalKb - system.memAvailableKb)
  var memoryPercent = system.memTotalKb > 0 ? clamp(memoryUsedKb * 100 / system.memTotalKb, 0, 100) : 0
  var sampleSeconds = previous && previous.system ? system.uptime - previous.system.uptime : 0
  if (current.disk) {
    var oldDisk = previous ? previous.disk : null
    current.disk.readRate = oldDisk && sampleSeconds > 0
      ? Math.max(0, current.disk.readSectors - oldDisk.readSectors) * 512 / sampleSeconds : 0
    current.disk.writeRate = oldDisk && sampleSeconds > 0
      ? Math.max(0, current.disk.writeSectors - oldDisk.writeSectors) * 512 / sampleSeconds : 0
  }
  var previousProcesses = {}
  if (previous && previous.processes) {
    for (var p = 0; p < previous.processes.length; p++) {
      var previousProcess = previous.processes[p]
      previousProcesses[previousProcess.pid] = previousProcess
    }
  }
  var rows = []
  for (var i = 0; i < current.processes.length; i++) {
    var proc = current.processes[i]
    var oldProcess = previousProcesses[proc.pid]
    var sameInstance = oldProcess && oldProcess.starttime === proc.starttime
    var procDelta = sameInstance ? Math.max(0, proc.ticks - oldProcess.ticks) : 0
    var procCpu = totalDelta > 0 ? clamp(procDelta * system.cpuCount * 100 / totalDelta, 0, system.cpuCount * 100) : 0
    rows.push({
      pid: proc.pid, name: proc.name,
      cpu: procCpu,
      cpuTopPercent: procCpu,
      cpuTotalPercent: procCpu / system.cpuCount,
      cpuEquivalent: procCpu / 100,
      memoryBytes: proc.rssPages * system.pageSize,
      memoryPercent: system.memTotalKb > 0 ? clamp(proc.rssPages * system.pageSize * 100 / (system.memTotalKb * 1024), 0, 100) : 0
    })
  }
  return {
    raw: current,
    cpu: cpuPercent,
    temperature: system.tempMilli > 0 ? system.tempMilli / 1000 : -1,
    memoryUsedBytes: memoryUsedKb * 1024,
    memoryTotalBytes: system.memTotalKb * 1024,
    memoryPercent: memoryPercent,
    uptime: system.uptime,
    disk: current.disk,
    gpu: current.gpu,
    processes: rows
  }
}

function topProcesses(rows, criterion, limit) {
  var copy = (rows || []).slice()
  copy.sort(function(a, b) {
    var delta = criterion === "memory" ? b.memoryBytes - a.memoryBytes : b.cpuTopPercent - a.cpuTopPercent
    return delta !== 0 ? delta : a.pid - b.pid
  })
  return copy.slice(0, limit || 5)
}

function formatBytes(value) {
  var bytes = Math.max(0, number(value))
  var units = ["B", "KiB", "MiB", "GiB", "TiB"]
  var index = 0
  while (bytes >= 1024 && index < units.length - 1) { bytes /= 1024; index++ }
  var digits = index >= 3 ? 1 : (index === 2 && bytes < 10 ? 1 : 0)
  return bytes.toFixed(digits) + " " + units[index]
}

function formatUptime(seconds) {
  var total = Math.max(0, Math.floor(number(seconds)))
  var days = Math.floor(total / 86400)
  var hours = Math.floor((total % 86400) / 3600)
  var minutes = Math.floor((total % 3600) / 60)
  if (days > 0) return days + "d " + hours + "h"
  if (hours > 0) return hours + "h " + minutes + "m"
  return minutes + "m"
}

function status(cpu, memory, temperature, gpu, disk) {
  var gpuTemperature = gpu ? number(gpu.temperature, -1) : -1
  var diskUsage = disk && disk.total > 0 ? disk.used * 100 / disk.total : 0
  var health = {
    title: "Running smoothly",
    level: 0,
    cpuWarning: cpu >= THRESHOLDS.cpu.warning,
    cpuCritical: cpu >= THRESHOLDS.cpu.critical,
    cpuTemperatureWarning: temperature >= THRESHOLDS.cpuTemperature.warning,
    cpuTemperatureCritical: temperature >= THRESHOLDS.cpuTemperature.critical,
    memoryWarning: memory >= THRESHOLDS.memory.warning,
    memoryCritical: memory >= THRESHOLDS.memory.critical,
    gpuTemperatureWarning: gpuTemperature >= THRESHOLDS.gpuTemperature.warning,
    gpuTemperatureCritical: gpuTemperature >= THRESHOLDS.gpuTemperature.critical,
    storageWarning: diskUsage >= THRESHOLDS.storage.warning,
    storageCritical: diskUsage >= THRESHOLDS.storage.critical
  }
  if (health.cpuTemperatureCritical) health.title = "Critical CPU temperature"
  else if (health.gpuTemperatureCritical) health.title = "Critical GPU temperature"
  else if (health.memoryCritical) health.title = "Critical memory usage"
  else if (health.storageCritical) health.title = "Storage critically full"
  else if (health.cpuCritical) health.title = "Critical CPU load"
  else if (health.cpuTemperatureWarning) health.title = "High CPU temperature"
  else if (health.gpuTemperatureWarning) health.title = "High GPU temperature"
  else if (health.memoryWarning) health.title = "High memory usage"
  else if (health.storageWarning) health.title = "Storage almost full"
  else if (health.cpuWarning) health.title = "High CPU load"
  health.level = health.cpuCritical || health.cpuTemperatureCritical || health.memoryCritical
    || health.gpuTemperatureCritical || health.storageCritical ? 2
    : health.cpuWarning || health.cpuTemperatureWarning || health.memoryWarning
      || health.gpuTemperatureWarning || health.storageWarning ? 1 : 0
  return health
}
