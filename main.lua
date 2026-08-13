local VERSION = "1.3.0"
local MOD_ID = "performance_monitor"
local GENERATION = {}
local unpack = table.unpack or unpack

local function pack(...)
  return { n = select("#", ...), ... }
end

local function clamp0(v)
  v = tonumber(v) or 0
  return v > 0 and v or 0
end

return function(mod)
  local gameRef
  local visible = true
  local detailed = false
  local extremeCompact = false
  local now = (love and love.timer and love.timer.getTime) or os.clock

  local TARGET_MS = 1000 / 60
  local SLOW_MS = 18.5
  local SEVERE_MS = 33.3
  local DEEP_INSTRUCTION_INTERVAL = 10000
  local DIAGNOSTIC_SECONDS = 10.0

  -- -----------------------------------------------------------------------
  -- Global frame / renderer stats
  -- -----------------------------------------------------------------------
  local lastHudTime = nil
  local lastStatsTime = 0
  local lastSecondTime = now()
  local frameSamples, frameSampleMax, frameSamplePos, frameSampleCount = {}, 300, 1, 0
  local logicSteps, logicPerSecond, logicWindowSteps = 0, 0, 0
  local f3WasDown, f4WasDown, f6WasDown, f7WasDown, f8WasDown, f9WasDown = false, false, false, false, false, false
  local padChordWasDown = { up = false, down = false, left = false, right = false }
  local padChordPending = {}
  local controllerMode = false
  local colorTheme = 1
  local overlayFont
  local controllerBindFont
  local COLOR_THEME_FILE = "performance_monitor_theme.txt"
  local UI_STATE_FILE = "performance_monitor_ui.txt"
  if love and love.filesystem and love.filesystem.read then
    local ok, saved = pcall(love.filesystem.read, COLOR_THEME_FILE)
    local value = ok and tonumber(saved) or nil
    if value and value >= 1 and value <= 5 then colorTheme = math.floor(value) end
  end
  if love and love.filesystem and love.filesystem.read then
    local ok, saved = pcall(love.filesystem.read, UI_STATE_FILE)
    if ok and type(saved) == "string" then
      local savedVisible, savedDetailed, savedController, savedExtreme = saved:match(
        "visible=(%d);detailed=(%d);controller=(%d);extreme=(%d)")
      if not savedVisible then
        savedVisible, savedDetailed, savedController = saved:match(
          "visible=(%d);detailed=(%d);controller=(%d)")
      end
      if not savedVisible then
        savedVisible, savedDetailed = saved:match("visible=(%d);detailed=(%d)")
      end
      if savedVisible then visible = savedVisible == "1" end
      if savedDetailed then detailed = savedDetailed == "1" end
      if savedController then controllerMode = savedController == "1" end
      if savedExtreme then extremeCompact = savedExtreme == "1" end
    end
  end
  local function saveUiState()
    if love and love.filesystem and love.filesystem.write then
      pcall(love.filesystem.write, UI_STATE_FILE,
        "visible=" .. (visible and "1" or "0") .. ";detailed=" .. (detailed and "1" or "0")
          .. ";controller=" .. (controllerMode and "1" or "0")
          .. ";extreme=" .. (extremeCompact and "1" or "0"))
    end
  end
  local function cycleDisplayMode()
    if detailed then
      detailed = false
      extremeCompact = true
    elseif extremeCompact then
      extremeCompact = false
    else
      detailed = true
    end
    saveUiState()
  end

  local snapshot = {
    fps = 0, frameMs = 0, avgMs = 0, worstMs = 0, low1 = 0,
    luaMB = 0, textureMB = 0,
    drawcalls = 0, batched = 0, canvasswitches = 0,
    images = 0, canvases = 0, fonts = 0, shaderswitches = 0,
    speed = 1, top = "-", map = "-",
    modCpuMsPerSec = 0, modCpuPercent = 0,
  }

  local function pushFrameSample(ms)
    frameSamples[frameSamplePos] = ms
    frameSamplePos = frameSamplePos % frameSampleMax + 1
    if frameSampleCount < frameSampleMax then frameSampleCount = frameSampleCount + 1 end
  end

  local function computeFrameStats()
    if frameSampleCount == 0 then return 0, 0, 0 end
    local values, sum, worst = {}, 0, 0
    for i = 1, frameSampleCount do
      local v = frameSamples[i] or 0
      values[#values + 1] = v
      sum = sum + v
      if v > worst then worst = v end
    end
    table.sort(values)
    local avg = sum / #values
    local slowCount = math.max(1, math.ceil(#values * 0.01))
    local slowSum = 0
    for i = #values - slowCount + 1, #values do slowSum = slowSum + values[i] end
    local slowMs = slowSum / slowCount
    local low1 = slowMs > 0 and (1000 / slowMs) or 0
    return avg, worst, low1
  end

  local function safeGraphicsStats()
    if not (love and love.graphics and love.graphics.getStats) then return {} end
    local ok, stats = pcall(love.graphics.getStats)
    return ok and type(stats) == "table" and stats or {}
  end

  local function graphicsCounters()
    local s = safeGraphicsStats()
    return tonumber(s.drawcalls) or 0,
           tonumber(s.canvasswitches) or 0,
           tonumber(s.shaderswitches) or 0
  end

  local function topStateName(game)
    local top = game and game.stack and game.stack.top and game.stack:top()
    if type(top) ~= "table" then return "-" end
    return tostring(top.screenId or top.title or "-")
  end

  local function activityState(game)
    local top = game and game.stack and game.stack.top and game.stack:top()
    local stackStates = game and game.stack and game.stack.states
    if type(stackStates) == "table" then
      for i = #stackStates, 1, -1 do
        if type(stackStates[i]) == "table" and stackStates[i].isBattle then
          return "BATTLE"
        end
      end
    end
    if type(top) == "table" and top.isTextBox then return "TALKING" end
    local overworld = game and game.overworld
    local player = overworld and overworld.player
    if player then
      if player.moving or (player.bumpFrames and player.bumpFrames > 0) then
        return "MOVING"
      end
      return "IDLE"
    end
    return topStateName(game)
  end

  local function mapName(game)
    local ow = game and game.overworld
    local map = ow and ow.map
    return tostring((map and (map.id or (map.def and map.def.label))) or "-")
  end

  -- -----------------------------------------------------------------------
  -- Portable diagnostic export helpers
  -- -----------------------------------------------------------------------
  local REPORT_LATEST_JSON = "performance_report_latest.json"
  local REPORT_LATEST_TEXT = "performance_report_latest.txt"
  local REPORT_ARCHIVE_DIR = "performance_reports"

  local exportState = {
    relativeJson = nil,
    relativeText = nil,
    archiveJson = nil,
    archiveText = nil,
    absoluteJson = nil,
    error = nil,
    exportedAt = nil,
  }

  local function jsonEscape(value)
    local text = tostring(value or "")
    return '"' .. text:gsub('[%z\1-\31\\"]', function(ch)
      if ch == '"' then return '\\"' end
      if ch == "\\" then return "\\\\" end
      if ch == "\b" then return "\\b" end
      if ch == "\f" then return "\\f" end
      if ch == "\n" then return "\\n" end
      if ch == "\r" then return "\\r" end
      if ch == "\t" then return "\\t" end
      return string.format("\\u%04x", ch:byte())
    end) .. '"'
  end

  local function tableIsArray(value)
    local max, count = 0, 0
    for k in pairs(value) do
      if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false, 0 end
      if k > max then max = k end
      count = count + 1
    end
    if max ~= count then return false, 0 end
    return true, max
  end

  local function jsonEncode(value, seen)
    local tv = type(value)
    if tv == "nil" then return "null" end
    if tv == "boolean" then return value and "true" or "false" end
    if tv == "number" then
      if value ~= value or value == math.huge or value == -math.huge then
        return "null"
      end
      return string.format("%.10g", value)
    end
    if tv == "string" then return jsonEscape(value) end
    if tv ~= "table" then return jsonEscape(tostring(value)) end

    seen = seen or {}
    if seen[value] then return jsonEscape("<cycle>") end
    seen[value] = true

    local isArray, n = tableIsArray(value)
    local parts = {}
    if isArray then
      for i = 1, n do parts[#parts + 1] = jsonEncode(value[i], seen) end
      seen[value] = nil
      return "[" .. table.concat(parts, ",") .. "]"
    end

    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, key in ipairs(keys) do
      local v = value[key]
      if v ~= nil then
        parts[#parts + 1] = jsonEscape(key) .. ":" .. jsonEncode(v, seen)
      end
    end
    seen[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
  end

  local function copyStringArray(value)
    local out = {}
    for _, v in ipairs(type(value) == "table" and value or {}) do
      out[#out + 1] = tostring(v)
    end
    return out
  end

  local function captureLoadedMods()
    local out, order = {}, {}
    local loader = gameRef and gameRef.mods
    if not loader then return out, order end

    local ok, status = pcall(loader.status, loader)
    if not ok or type(status) ~= "table" then return out, order end
    order = copyStringArray(status.order)

    for _, mf in ipairs(type(status.loaded) == "table" and status.loaded or {}) do
      out[#out + 1] = {
        id = tostring(mf.id or "?"),
        name = tostring(mf.name or mf.id or "?"),
        version = tostring(mf.version or "?"),
        api = tonumber(mf.api) or 1,
        profile = tostring(mf.profile or "content"),
        priority = tonumber(mf.priority) or 0,
        affectsLink = mf.affects_link == true,
        dependencies = copyStringArray(mf.dependencies),
        optionalDependencies = copyStringArray(mf.optional_dependencies),
        permissions = copyStringArray(mf.permissions),
      }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out, order
  end

  local function captureEnvironment(game)
    local env = {
      lua = tostring(_VERSION or "?"),
      gameVersion = "?",
      engineVersion = "?",
      modApi = nil,
      os = "?",
      loveVersion = "?",
      renderer = {},
      window = {},
      gameOptions = {},
    }

    if jit and jit.version then env.jit = tostring(jit.version) end

    local okVersion, Version = pcall(require, "src.core.Version")
    if okVersion and type(Version) == "table" then
      env.engineVersion = tostring(Version.engine or "?")
      env.modApi = tonumber(Version.modApi)
    end

    local okGameVersion, GameVersion = pcall(require, "src.core.GameVersion")
    if okGameVersion and type(GameVersion) == "table" and GameVersion.get then
      local ok, value = pcall(GameVersion.get)
      if ok then env.gameVersion = tostring(value) end
    end

    if love then
      if love.system and love.system.getOS then
        local ok, value = pcall(love.system.getOS)
        if ok then env.os = tostring(value) end
      end
      if love.getVersion then
        local ok, major, minor, revision, codename = pcall(love.getVersion)
        if ok then
          env.loveVersion = ("%s.%s.%s %s"):format(
            tostring(major or "?"), tostring(minor or "?"),
            tostring(revision or "?"), tostring(codename or ""))
        end
      end
      if love.graphics then
        if love.graphics.getRendererInfo then
          local ok, name, version, vendor, device = pcall(love.graphics.getRendererInfo)
          if ok then
            env.renderer = {
              name = tostring(name or "?"),
              version = tostring(version or "?"),
              vendor = tostring(vendor or "?"),
              device = tostring(device or "?"),
            }
          end
        end
        if love.graphics.getDimensions then
          local ok, w, h = pcall(love.graphics.getDimensions)
          if ok then env.window.width, env.window.height = w, h end
        end
        if love.graphics.getPixelDimensions then
          local ok, w, h = pcall(love.graphics.getPixelDimensions)
          if ok then env.window.pixelWidth, env.window.pixelHeight = w, h end
        end
        if love.graphics.getDPIScale then
          local ok, dpi = pcall(love.graphics.getDPIScale)
          if ok then env.window.dpiScale = dpi end
        end
      end
    end

    local opts = game and game.save and game.save.options
    if type(opts) == "table" then
      for _, key in ipairs({
        "speed", "battleLayout", "battleFit", "battleBg",
        "uiLayout", "zoom", "colors", "tilt"
      }) do
        local v = opts[key]
        if type(v) == "string" or type(v) == "number" or type(v) == "boolean" then
          env.gameOptions[key] = v
        end
      end
    end
    return env
  end

  local function frameDistribution(values, duration)
    local n = #(values or {})
    if n == 0 then
      return {
        frames = 0, presentedFps = 0, averageMs = 0, medianMs = 0,
        p95Ms = 0, p99Ms = 0, worstMs = 0, onePercentLowFps = 0,
        missedBudgetFrames = 0, missedBudgetPct = 0,
      }
    end

    local sorted, sum = {}, 0
    local missed = 0
    for i, v in ipairs(values) do
      v = tonumber(v) or 0
      sorted[i] = v
      sum = sum + v
      if v > TARGET_MS then missed = missed + 1 end
    end
    table.sort(sorted)
    local function percentile(pct)
      local idx = math.max(1, math.min(n, math.ceil(n * pct)))
      return sorted[idx]
    end

    local slowCount = math.max(1, math.ceil(n * 0.01))
    local slowSum = 0
    for i = n - slowCount + 1, n do slowSum = slowSum + sorted[i] end
    local onePctMs = slowSum / slowCount

    return {
      frames = n,
      presentedFps = duration and duration > 0 and (n / duration) or 0,
      averageMs = sum / n,
      medianMs = percentile(0.50),
      p95Ms = percentile(0.95),
      p99Ms = percentile(0.99),
      worstMs = sorted[n],
      onePercentLowFps = onePctMs > 0 and (1000 / onePctMs) or 0,
      missedBudgetFrames = missed,
      missedBudgetPct = missed * 100 / n,
    }
  end

  local function topMapRows(map, limit, scaleKey)
    local rows = {}
    for id, value in pairs(map or {}) do
      rows[#rows + 1] = { modId = tostring(id), value = tonumber(value) or 0 }
    end
    table.sort(rows, function(a, b) return a.value > b.value end)
    local out = {}
    for i = 1, math.min(limit or 3, #rows) do
      local row = rows[i]
      if scaleKey == "ms" then
        out[#out + 1] = { modId = row.modId, ms = row.value * 1000 }
      else
        out[#out + 1] = { modId = row.modId, samples = row.value }
      end
    end
    return out
  end

  local function buildTextReport(report)
    local lines = {}
    local function add(fmt, ...)
      if select("#", ...) > 0 then
        lines[#lines + 1] = string.format(fmt, ...)
      else
        lines[#lines + 1] = tostring(fmt)
      end
    end

    add("GEN1RECOMP PERFORMANCE REPORT")
    add("Monitor: %s", tostring(report.monitorVersion))
    add("Capture: %s", tostring(report.captureId))
    add("Generated: %s", tostring(report.generatedUtc))
    add("Duration: %.3f s", tonumber(report.capture.durationSeconds) or 0)
    add("Engine: %s | Game: %s | LÖVE: %s | OS: %s",
      tostring(report.environment.engineVersion),
      tostring(report.environment.gameVersion),
      tostring(report.environment.loveVersion),
      tostring(report.environment.os))
    local r = report.environment.renderer or {}
    add("Renderer: %s | %s | %s | %s",
      tostring(r.name or "?"), tostring(r.version or "?"),
      tostring(r.vendor or "?"), tostring(r.device or "?"))
    add("Loaded mods: %d", #(report.mods or {}))
    add("")

    local f = report.frames or {}
    add("FRAME FLUIDITY")
    add("Frames: %d | Presented FPS: %.2f | Avg: %.3f ms | 1%% low: %.2f FPS",
      tonumber(f.frames) or 0, tonumber(f.presentedFps) or 0,
      tonumber(f.averageMs) or 0, tonumber(f.onePercentLowFps) or 0)
    add("Median: %.3f ms | P95: %.3f ms | P99: %.3f ms | Worst: %.3f ms",
      tonumber(f.medianMs) or 0, tonumber(f.p95Ms) or 0,
      tonumber(f.p99Ms) or 0, tonumber(f.worstMs) or 0)
    add("Missed 16.67ms budget: %d (%.1f%%) | Slow > %.1fms: %d | Severe >= %.1fms: %d",
      tonumber(f.missedBudgetFrames) or 0, tonumber(f.missedBudgetPct) or 0,
      tonumber(report.thresholds.slowMs) or 0,
      tonumber(report.capture.slowFrames) or 0,
      tonumber(report.thresholds.severeMs) or 0,
      tonumber(report.capture.severeFrames) or 0)
    add("Unattributed slow frames: %d", tonumber(report.capture.unattributedSlowFrames) or 0)
    add("")

    add("MOD FLUIDITY IMPACT")
    for i, row in ipairs(report.modsImpact or {}) do
      add("#%d [%s] %s (%s)", i, tostring(row.verdict), tostring(row.id), tostring(row.name))
      add("  CPU %.2f%% | %.2f ms/s | STUT %.1f%% | MAX %.3f ms | DRAW %.1f/s | DEEP %.1f%%",
        tonumber(row.percent) or 0, tonumber(row.msPerSec) or 0,
        tonumber(row.stutterPct) or 0, tonumber(row.maxMs) or 0,
        tonumber(row.drawsPerSec) or 0, tonumber(row.deepPct) or 0)
      add("  HOT %s", tostring(row.hot or "-"))
      add("  DEEPHOT %s", tostring(row.deepHot or "-"))
    end
    add("")

    add("TOP SLOW FRAMES")
    for i = 1, math.min(30, #(report.slowFrames or {})) do
      local sf = report.slowFrames[i]
      add("#%d t=%.3fs frame=%.3fms winner=%s method=%s state=%s map=%s",
        i, tonumber(sf.t) or 0, tonumber(sf.frameMs) or 0,
        tostring(sf.winner or "UNATTRIBUTED"), tostring(sf.method or "-"),
        tostring(sf.state or "-"), tostring(sf.map or "-"))
    end
    add("")
    add("Upload performance_report_latest.json for full machine-readable analysis.")
    return table.concat(lines, "\n") .. "\n"
  end

  local function exportDiagnosticReport(report)
    exportState.error = nil
    if type(report) ~= "table" then
      exportState.error = "no completed diagnostic report"
      return false
    end
    if not (love and love.filesystem and love.filesystem.write) then
      exportState.error = "LÖVE filesystem API unavailable"
      return false
    end

    local stamp
    if os and os.date then
      local ok, value = pcall(os.date, "%Y%m%d_%H%M%S")
      if ok then stamp = value end
    end
    stamp = stamp or tostring(math.floor(now() * 1000))

    local archiveJson = REPORT_ARCHIVE_DIR .. "/performance_report_" .. stamp .. ".json"
    local archiveText = REPORT_ARCHIVE_DIR .. "/performance_report_" .. stamp .. ".txt"

    report.export = {
      latestJson = REPORT_LATEST_JSON,
      latestText = REPORT_LATEST_TEXT,
      archiveJson = archiveJson,
      archiveText = archiveText,
    }

    local jsonText = jsonEncode(report)
    local textReport = buildTextReport(report)

    local okDir = true
    if love.filesystem.createDirectory then
      local ok, result = pcall(love.filesystem.createDirectory, REPORT_ARCHIVE_DIR)
      okDir = ok and result ~= false
    end
    if not okDir then
      exportState.error = "could not create " .. REPORT_ARCHIVE_DIR
      return false
    end

    local function write(path, data)
      local ok, result, err = pcall(love.filesystem.write, path, data)
      if not ok or result == false or result == nil then
        return false, tostring(err or result or "write failed")
      end
      return true
    end

    local ok1, err1 = write(REPORT_LATEST_JSON, jsonText)
    local ok2, err2 = write(REPORT_LATEST_TEXT, textReport)
    local ok3, err3 = write(archiveJson, jsonText)
    local ok4, err4 = write(archiveText, textReport)
    if not (ok1 and ok2 and ok3 and ok4) then
      exportState.error = table.concat({
        ok1 and "" or ("latest json: " .. tostring(err1)),
        ok2 and "" or ("latest txt: " .. tostring(err2)),
        ok3 and "" or ("archive json: " .. tostring(err3)),
        ok4 and "" or ("archive txt: " .. tostring(err4)),
      }, " ")
      return false
    end

    exportState.relativeJson = REPORT_LATEST_JSON
    exportState.relativeText = REPORT_LATEST_TEXT
    exportState.archiveJson = archiveJson
    exportState.archiveText = archiveText
    exportState.exportedAt = stamp

    local saveDir
    if love.filesystem.getSaveDirectory then
      local ok, value = pcall(love.filesystem.getSaveDirectory)
      if ok then saveDir = tostring(value) end
    end
    if saveDir and saveDir ~= "" then
      exportState.absoluteJson = saveDir:gsub("[/\\]+$", "") .. "/" .. REPORT_LATEST_JSON
      mod.log:info("Performance report exported: %s", exportState.absoluteJson)
    else
      mod.log:info("Performance report exported: %s", REPORT_LATEST_JSON)
    end
    return true
  end

  -- -----------------------------------------------------------------------
  -- Runtime hook/event profiler
  -- -----------------------------------------------------------------------
  local profiler = {
    current = {},
    ranked = {},
    windowStart = now(),
    lastScan = 0,
    instrumentedHooks = 0,
    instrumentedEvents = 0,
    frameDirect = {},
    frameDeep = {},
    windowSlowFrames = 0,
    windowSevereFrames = 0,
    windowUnattributed = 0,
    windowStutterWins = {},
  }

  local function newBucket()
    return {
      total = 0, calls = 0, max = 0,
      hooks = 0, events = 0,
      draws = 0, canvas = 0, shaders = 0,
      slots = {},
    }
  end

  local function bucketFor(map, owner)
    local b = map[owner]
    if not b then
      b = newBucket()
      map[owner] = b
    end
    return b
  end

  local function slotRecord(bucket, key, elapsed)
    local s = bucket.slots[key]
    if not s then
      s = { total = 0, calls = 0, max = 0 }
      bucket.slots[key] = s
    end
    s.total = s.total + elapsed
    s.calls = s.calls + 1
    if elapsed > s.max then s.max = elapsed end
  end

  local diagnostic = {
    active = false,
    started = 0,
    duration = 0,
    totals = {},
    slowFrames = 0,
    severeFrames = 0,
    unattributed = 0,
    stutter = {},
    report = nil,
    deepAll = 0,
    deepMod = 0,
    deep = {},
    deepHotspots = {},
    deepAvailable = false,
    deepReason = nil,
    frameTimesMs = {},
    slowFrameDetails = {},
    series = {},
    lastSeriesSample = 0,
    logicStepsStart = 0,
    loadedMods = {},
    loadOrder = {},
    environment = {},
    captureId = nil,
  }

  local function diagStutter(owner)
    local s = diagnostic.stutter[owner]
    if not s then
      s = { wins = 0, directWins = 0, deepWins = 0, touched = 0, winnerMs = 0 }
      diagnostic.stutter[owner] = s
    end
    return s
  end

  local function record(owner, kind, slot, elapsed, draws, canvas, shaders)
    if not owner or owner == MOD_ID then return end
    -- F3 hides the monitor completely.  Keep the hook wrappers installed so
    -- the monitor can resume without a reload, but do not accumulate timing,
    -- event, or draw statistics while the HUD is hidden.
    if not visible then return end
    elapsed = clamp0(elapsed)

    local b = bucketFor(profiler.current, owner)
    b.total = b.total + elapsed
    b.calls = b.calls + 1
    if elapsed > b.max then b.max = elapsed end
    if kind == "hook" then b.hooks = b.hooks + 1 else b.events = b.events + 1 end
    b.draws = b.draws + clamp0(draws)
    b.canvas = b.canvas + clamp0(canvas)
    b.shaders = b.shaders + clamp0(shaders)
    slotRecord(b, slot, elapsed)

    profiler.frameDirect[owner] = (profiler.frameDirect[owner] or 0) + elapsed

    if diagnostic.active then
      local d = bucketFor(diagnostic.totals, owner)
      d.total = d.total + elapsed
      d.calls = d.calls + 1
      if elapsed > d.max then d.max = elapsed end
      if kind == "hook" then d.hooks = d.hooks + 1 else d.events = d.events + 1 end
      d.draws = d.draws + clamp0(draws)
      d.canvas = d.canvas + clamp0(canvas)
      d.shaders = d.shaders + clamp0(shaders)
      slotRecord(d, slot, elapsed)
    end
  end

  local function topSlot(bucket)
    if not bucket or type(bucket.slots) ~= "table" then return "-", 0 end
    local best, bestTotal = "-", 0
    for key, s in pairs(bucket.slots) do
      if s.total > bestTotal then best, bestTotal = key, s.total end
    end
    return best, bestTotal
  end

  local function displayName(owner)
    local mods = gameRef and gameRef.mods and gameRef.mods.mods
    local loaded = mods and mods[owner]
    local mf = loaded and loaded.manifest
    return tostring((mf and mf.name) or owner)
  end

  local function rowFromBucket(owner, b, elapsed, stutterWins, slowFrames)
    local msPerSec = elapsed > 0 and (b.total * 1000 / elapsed) or 0
    local hot = topSlot(b)
    return {
      id = owner,
      name = displayName(owner),
      msPerSec = msPerSec,
      percent = msPerSec / 10,
      maxMs = b.max * 1000,
      callsPerSec = elapsed > 0 and (b.calls / elapsed) or 0,
      drawsPerSec = elapsed > 0 and (b.draws / elapsed) or 0,
      canvasPerSec = elapsed > 0 and (b.canvas / elapsed) or 0,
      shaderPerSec = elapsed > 0 and (b.shaders / elapsed) or 0,
      hooks = b.hooks,
      events = b.events,
      stutterPct = slowFrames > 0 and ((stutterWins or 0) * 100 / slowFrames) or 0,
      hot = hot,
    }
  end

  local function closeProfilerWindow(t)
    local elapsed = t - profiler.windowStart
    if elapsed < 1.0 then return end

    local ranked, totalAll = {}, 0
    for owner, b in pairs(profiler.current) do
      local row = rowFromBucket(owner, b, elapsed,
        profiler.windowStutterWins[owner] or 0, profiler.windowSlowFrames)
      ranked[#ranked + 1] = row
      totalAll = totalAll + row.msPerSec
    end
    table.sort(ranked, function(a, b)
      if a.stutterPct ~= b.stutterPct then return a.stutterPct > b.stutterPct end
      if a.msPerSec ~= b.msPerSec then return a.msPerSec > b.msPerSec end
      return a.maxMs > b.maxMs
    end)

    profiler.current = {}
    profiler.ranked = ranked
    profiler.windowStart = t
    snapshot.modCpuMsPerSec = totalAll
    snapshot.modCpuPercent = totalAll / 10
    profiler.windowSlowFrames = 0
    profiler.windowSevereFrames = 0
    profiler.windowUnattributed = 0
    profiler.windowStutterWins = {}
  end

  -- -----------------------------------------------------------------------
  -- Deep source/provenance sampler
  -- -----------------------------------------------------------------------
  local functionProvenance = setmetatable({}, { __mode = "k" })
  local sourceRoots = {}
  local deepInstalled = false
  local deepHookFn = nil

  local function normalizePath(p)
    p = tostring(p or "")
    p = p:gsub("^@", ""):gsub("\\", "/")
    p = p:gsub("//+", "/")
    return p:lower()
  end

  local function rebuildSourceRoots()
    sourceRoots = {}
    local mods = gameRef and gameRef.mods and gameRef.mods.mods
    for id, row in pairs(mods or {}) do
      if id ~= MOD_ID and row and row.path then
        sourceRoots[#sourceRoots + 1] = { id = id, path = normalizePath(row.path) }
      end
    end
    table.sort(sourceRoots, function(a, b) return #a.path > #b.path end)
  end

  local function ownerForSource(source)
    local s = normalizePath(source)
    if s == "" then return nil end
    for _, r in ipairs(sourceRoots) do
      if s == r.path
          or s:sub(1, #r.path + 1) == r.path .. "/"
          or s:find("/" .. r.path .. "/", 1, true) then
        return r.id
      end
    end
    return nil
  end

  local function provenanceWalk(value, owner, label, seen, depth, budget)
    if budget.n <= 0 or depth > 10 then return end
    local tv = type(value)
    if tv == "function" then
      if not functionProvenance[value] then
        functionProvenance[value] = { owner = owner, label = label }
      end
      budget.n = budget.n - 1
      return
    end
    if tv ~= "table" or seen[value] then return end
    seen[value] = true
    budget.n = budget.n - 1
    for k, v in pairs(value) do
      if budget.n <= 0 then break end
      local child = label .. "." .. tostring(k)
      provenanceWalk(v, owner, child, seen, depth + 1, budget)
    end
  end

  local function rebuildFunctionProvenance()
    functionProvenance = setmetatable({}, { __mode = "k" })
    rebuildSourceRoots()
    if not (gameRef and gameRef.mods) then return end

    local budget = { n = 75000 }
    for regName, registry in pairs(gameRef.mods.content or {}) do
      if type(registry) == "table" and type(registry.ops) == "table" then
        for id, list in pairs(registry.ops) do
          for _, entry in ipairs(list or {}) do
            local owner = entry.owner
            if owner and owner ~= MOD_ID
                and gameRef.mods.mods and gameRef.mods.mods[owner] then
              provenanceWalk(entry.value, owner,
                "registry:" .. tostring(regName) .. ":" .. tostring(id),
                {}, 0, budget)
            end
          end
        end
      end
    end

    -- Exported callbacks are also owned unambiguously by their publishing mod.
    for owner, exports in pairs(gameRef.mods.exports or {}) do
      if owner ~= MOD_ID and gameRef.mods.mods and gameRef.mods.mods[owner] then
        provenanceWalk(exports, owner, "exports:" .. tostring(owner), {}, 0, budget)
      end
    end
  end

  local function shortSource(source)
    local s = tostring(source or "?"):gsub("^@", ""):gsub("\\", "/")
    local tail = s:match("([^/]+/[^/]+)$") or s:match("([^/]+)$") or s
    return tail
  end

  local function deepSample()
    if not diagnostic.active then return end
    if not (debug and debug.getinfo) then return end

    local info = debug.getinfo(2, "fSl")
    if not info then return end

    local prov = info.func and functionProvenance[info.func] or nil
    local owner = prov and prov.owner or ownerForSource(info.source or info.short_src)
    if owner == MOD_ID then return end

    diagnostic.deepAll = diagnostic.deepAll + 1
    if not owner then return end

    diagnostic.deepMod = diagnostic.deepMod + 1
    local d = diagnostic.deep[owner]
    if not d then d = { samples = 0 }; diagnostic.deep[owner] = d end
    d.samples = d.samples + 1
    profiler.frameDeep[owner] = (profiler.frameDeep[owner] or 0) + 1

    local hot = prov and prov.label
      or (shortSource(info.source or info.short_src) .. ":" .. tostring(info.currentline or 0))
    local perOwner = diagnostic.deepHotspots[owner]
    if not perOwner then perOwner = {}; diagnostic.deepHotspots[owner] = perOwner end
    perOwner[hot] = (perOwner[hot] or 0) + 1
  end

  local function stopDeepSampler()
    if not deepInstalled then return end
    if debug and debug.gethook and debug.sethook then
      local current = debug.gethook()
      if current == deepHookFn then pcall(debug.sethook) end
    end
    deepInstalled = false
  end

  local function startDeepSampler()
    diagnostic.deepAvailable = false
    diagnostic.deepReason = nil
    if not (debug and debug.sethook and debug.gethook and debug.getinfo) then
      diagnostic.deepReason = "Lua debug API unavailable"
      return false
    end

    local existing = debug.gethook()
    if existing ~= nil then
      diagnostic.deepReason = "another debug profiler is already active"
      return false
    end

    rebuildFunctionProvenance()
    deepHookFn = deepSample
    local ok, err = pcall(debug.sethook, deepHookFn, "", DEEP_INSTRUCTION_INTERVAL)
    if not ok then
      diagnostic.deepReason = tostring(err)
      return false
    end
    deepInstalled = true
    diagnostic.deepAvailable = true
    return true
  end

  local function topDeepHotspot(owner)
    local map = diagnostic.deepHotspots[owner]
    local best, count = "-", 0
    for key, n in pairs(map or {}) do
      if n > count then best, count = key, n end
    end
    return best, count
  end

  -- -----------------------------------------------------------------------
  -- Runtime instrumentation
  -- -----------------------------------------------------------------------
  local function instrumentHookEntry(hookName, entry)
    if type(entry) ~= "table" or not entry.owner or entry.owner == MOD_ID then return false end
    if entry._performanceMonitor12Token == GENERATION then return false end

    -- Hot-reload safety: peel an older monitor wrapper back to the real callback.
    if entry._performanceMonitor12Original then
      entry.callback = entry._performanceMonitor12Original
      entry._performanceMonitor12Original = nil
      entry._performanceMonitor12 = nil
      entry._performanceMonitor12Token = nil
    elseif entry._performanceMonitor11Original then
      entry.callback = entry._performanceMonitor11Original
      entry._performanceMonitor11Original = nil
      entry._performanceMonitor11 = nil
    end

    if type(entry.callback) ~= "function" then return false end

    local original = entry.callback
    local owner = entry.owner
    local renderLike = tostring(hookName):match("^render%.") ~= nil
    local slot = "hook:" .. tostring(hookName)

    entry.callback = function(nextFn, ...)
      local downstreamTime = 0
      local downstreamDraw, downstreamCanvas, downstreamShader = 0, 0, 0

      local function measuredNext(...)
        local d0, c0, s0 = 0, 0, 0
        if renderLike then d0, c0, s0 = graphicsCounters() end
        local t0 = now()
        local res = pack(pcall(nextFn, ...))
        downstreamTime = downstreamTime + (now() - t0)
        if renderLike then
          local d1, c1, s1 = graphicsCounters()
          downstreamDraw = downstreamDraw + clamp0(d1 - d0)
          downstreamCanvas = downstreamCanvas + clamp0(c1 - c0)
          downstreamShader = downstreamShader + clamp0(s1 - s0)
        end
        if not res[1] then error(res[2], 0) end
        return unpack(res, 2, res.n)
      end

      local d0, c0, s0 = 0, 0, 0
      if renderLike then d0, c0, s0 = graphicsCounters() end
      local t0 = now()
      local res = pack(pcall(original, measuredNext, ...))
      local elapsed = (now() - t0) - downstreamTime

      local ownDraw, ownCanvas, ownShader = 0, 0, 0
      if renderLike then
        local d1, c1, s1 = graphicsCounters()
        ownDraw = clamp0((d1 - d0) - downstreamDraw)
        ownCanvas = clamp0((c1 - c0) - downstreamCanvas)
        ownShader = clamp0((s1 - s0) - downstreamShader)
      end

      record(owner, "hook", slot, elapsed, ownDraw, ownCanvas, ownShader)
      if not res[1] then error(res[2], 0) end
      return unpack(res, 2, res.n)
    end

    entry._performanceMonitor12 = true
    entry._performanceMonitor12Original = original
    entry._performanceMonitor12Token = GENERATION
    profiler.instrumentedHooks = profiler.instrumentedHooks + 1
    return true
  end

  local function instrumentEventEntry(eventName, entry)
    if type(entry) ~= "table" or not entry.owner or entry.owner == MOD_ID then return false end
    if entry._performanceMonitor12Token == GENERATION then return false end

    if entry._performanceMonitor12Original then
      entry.callback = entry._performanceMonitor12Original
      entry._performanceMonitor12Original = nil
      entry._performanceMonitor12 = nil
      entry._performanceMonitor12Token = nil
    elseif entry._performanceMonitor11Original then
      entry.callback = entry._performanceMonitor11Original
      entry._performanceMonitor11Original = nil
      entry._performanceMonitor11 = nil
    end

    if type(entry.callback) ~= "function" then return false end

    local original = entry.callback
    local owner = entry.owner
    local slot = "event:" .. tostring(eventName)

    entry.callback = function(...)
      local t0 = now()
      local res = pack(pcall(original, ...))
      record(owner, "event", slot, now() - t0, 0, 0, 0)
      if not res[1] then error(res[2], 0) end
      return unpack(res, 2, res.n)
    end

    entry._performanceMonitor12 = true
    entry._performanceMonitor12Original = original
    entry._performanceMonitor12Token = GENERATION
    profiler.instrumentedEvents = profiler.instrumentedEvents + 1
    return true
  end

  local runtime
  local function scanRuntime()
    if not runtime then
      local ok, r = pcall(require, "src.mods.Runtime")
      if not ok or type(r) ~= "table" then return end
      runtime = r
    end

    local hooks = runtime.hooks and runtime.hooks.chains
    if type(hooks) == "table" then
      for hookName, chain in pairs(hooks) do
        for _, entry in ipairs(type(chain) == "table" and chain or {}) do
          instrumentHookEntry(hookName, entry)
        end
      end
    end

    local listeners = runtime.events and runtime.events.listeners
    if type(listeners) == "table" then
      for eventName, list in pairs(listeners) do
        for _, entry in ipairs(type(list) == "table" and list or {}) do
          instrumentEventEntry(eventName, entry)
        end
      end
    end
  end

  -- -----------------------------------------------------------------------
  -- Slow-frame correlation + diagnostic report
  -- -----------------------------------------------------------------------
  local function frameTop(map)
    local owner, value = nil, 0
    for id, v in pairs(map or {}) do
      if v > value then owner, value = id, v end
    end
    return owner, value
  end

  local function finalizeFrame(frameMs)
    if diagnostic.active then
      diagnostic.frameTimesMs[#diagnostic.frameTimesMs + 1] = frameMs
    end

    if frameMs <= SLOW_MS then
      profiler.frameDirect = {}
      profiler.frameDeep = {}
      return
    end

    profiler.windowSlowFrames = profiler.windowSlowFrames + 1
    if frameMs >= SEVERE_MS then profiler.windowSevereFrames = profiler.windowSevereFrames + 1 end
    if diagnostic.active then
      diagnostic.slowFrames = diagnostic.slowFrames + 1
      if frameMs >= SEVERE_MS then diagnostic.severeFrames = diagnostic.severeFrames + 1 end
    end

    for owner, seconds in pairs(profiler.frameDirect) do
      if seconds >= 0.0005 and diagnostic.active then
        diagStutter(owner).touched = diagStutter(owner).touched + 1
      end
    end

    local directOwner, directSeconds = frameTop(profiler.frameDirect)
    local deepOwner, deepCount = frameTop(profiler.frameDeep)
    local winner, method = nil, nil
    if directOwner and directSeconds >= 0.0005 then
      winner, method = directOwner, "direct"
    elseif diagnostic.active and deepOwner and deepCount > 0 then
      winner, method = deepOwner, "deep"
    end

    if diagnostic.active then
      local gs = safeGraphicsStats()
      diagnostic.slowFrameDetails[#diagnostic.slowFrameDetails + 1] = {
        t = math.max(0, now() - diagnostic.started),
        frameMs = frameMs,
        winner = winner or "UNATTRIBUTED",
        method = method or "none",
        directWinner = directOwner,
        directWinnerMs = (directSeconds or 0) * 1000,
        deepWinner = deepOwner,
        deepWinnerSamples = deepCount or 0,
        directTop = topMapRows(profiler.frameDirect, 5, "ms"),
        deepTop = topMapRows(profiler.frameDeep, 5, "samples"),
        state = topStateName(gameRef),
        map = mapName(gameRef),
        drawcalls = tonumber(gs.drawcalls) or 0,
        canvasswitches = tonumber(gs.canvasswitches) or 0,
        shaderswitches = tonumber(gs.shaderswitches) or 0,
      }
    end

    if winner then
      profiler.windowStutterWins[winner] = (profiler.windowStutterWins[winner] or 0) + 1
      if diagnostic.active then
        local s = diagStutter(winner)
        s.wins = s.wins + 1
        if method == "direct" then
          s.directWins = s.directWins + 1
          s.winnerMs = s.winnerMs + directSeconds * 1000
        else
          s.deepWins = s.deepWins + 1
        end
      end
    else
      profiler.windowUnattributed = profiler.windowUnattributed + 1
      if diagnostic.active then diagnostic.unattributed = diagnostic.unattributed + 1 end
    end

    profiler.frameDirect = {}
    profiler.frameDeep = {}
  end

  local function classify(row, slowFrames)
    local strongStutter = slowFrames >= 3 and row.stutterPct >= 25
    if row.percent >= 20 or row.maxMs >= 16.7 or row.deepPct >= 25 or strongStutter then
      return "HIGH"
    end
    if row.percent >= 8 or row.maxMs >= 8 or row.deepPct >= 10
        or (slowFrames >= 3 and row.stutterPct >= 10) then
      return "MED"
    end
    return "LOW"
  end

  local function buildDiagnosticReport(t)
    diagnostic.duration = math.max(0.001, t - diagnostic.started)
    local rows, seen = {}, {}

    for owner, b in pairs(diagnostic.totals) do
      local s = diagnostic.stutter[owner] or {}
      local row = rowFromBucket(owner, b, diagnostic.duration,
        s.wins or 0, diagnostic.slowFrames)
      row.deepSamples = diagnostic.deep[owner] and diagnostic.deep[owner].samples or 0
      row.deepPct = diagnostic.deepAll > 0 and (row.deepSamples * 100 / diagnostic.deepAll) or 0
      row.deepHot = topDeepHotspot(owner)
      row.stutterDirect = s.directWins or 0
      row.stutterDeep = s.deepWins or 0
      row.stutterTouched = s.touched or 0
      row.winnerAvgMs = (s.directWins or 0) > 0 and ((s.winnerMs or 0) / s.directWins) or 0
      rows[#rows + 1] = row
      seen[owner] = true
    end

    -- A mod can be invisible to Runtime hooks/events but still show up in the
    -- deep sampler (direct class monkey-patch, custom quest callback, etc.).
    for owner, d in pairs(diagnostic.deep) do
      if not seen[owner] then
        local s = diagnostic.stutter[owner] or {}
        local row = rowFromBucket(owner, newBucket(), diagnostic.duration,
          s.wins or 0, diagnostic.slowFrames)
        row.deepSamples = d.samples or 0
        row.deepPct = diagnostic.deepAll > 0 and (row.deepSamples * 100 / diagnostic.deepAll) or 0
        row.deepHot = topDeepHotspot(owner)
        row.stutterDirect = s.directWins or 0
        row.stutterDeep = s.deepWins or 0
        row.stutterTouched = s.touched or 0
        row.winnerAvgMs = 0
        rows[#rows + 1] = row
      end
    end

    for _, row in ipairs(rows) do
      row.verdict = classify(row, diagnostic.slowFrames)
      local rank = row.verdict == "HIGH" and 3 or row.verdict == "MED" and 2 or 1
      -- Ordering only. The visible metrics stay raw and independently readable.
      row._rank = rank * 100000
        + row.stutterPct * 500
        + row.percent * 250
        + row.deepPct * 150
        + math.min(row.maxMs, 50) * 100
    end
    table.sort(rows, function(a, b) return a._rank > b._rank end)

    local captureId = diagnostic.captureId or ("perf-" .. tostring(math.floor(diagnostic.started * 1000)))
    local generatedUtc = tostring(captureId)
    if os and os.date then
      local ok, value = pcall(os.date, "!%Y-%m-%dT%H:%M:%SZ")
      if ok then generatedUtc = tostring(value) end
    end

    local frameStats = frameDistribution(diagnostic.frameTimesMs, diagnostic.duration)
    local logicDelta = math.max(0, logicSteps - (diagnostic.logicStepsStart or 0))

    diagnostic.report = {
      reportFormat = "gen1recomp-performance-report",
      reportVersion = 1,
      monitorVersion = VERSION,
      captureId = captureId,
      generatedUtc = generatedUtc,
      environment = diagnostic.environment,
      mods = diagnostic.loadedMods,
      modLoadOrder = diagnostic.loadOrder,
      thresholds = {
        targetFrameMs = TARGET_MS,
        slowMs = SLOW_MS,
        severeMs = SEVERE_MS,
        deepInstructionInterval = DEEP_INSTRUCTION_INTERVAL,
      },
      capture = {
        durationSeconds = diagnostic.duration,
        requestedSeconds = DIAGNOSTIC_SECONDS,
        logicSteps = logicDelta,
        logicStepsPerSecond = logicDelta / diagnostic.duration,
        slowFrames = diagnostic.slowFrames,
        severeFrames = diagnostic.severeFrames,
        unattributedSlowFrames = diagnostic.unattributed,
        deepSamplesAll = diagnostic.deepAll,
        deepSamplesAttributedToMods = diagnostic.deepMod,
        deepAvailable = diagnostic.deepAvailable,
        deepReason = diagnostic.deepReason,
        instrumentedHooks = profiler.instrumentedHooks,
        instrumentedEvents = profiler.instrumentedEvents,
      },
      frames = frameStats,
      frameTimesMs = diagnostic.frameTimesMs,
      slowFrames = diagnostic.slowFrameDetails,
      timeSeries = diagnostic.series,
      modsImpact = rows,
      analysisNotes = {
        "CPU is exclusive measured hook/event CPU; downstream next() time is removed.",
        "STUT is slow-frame winner correlation, not proof of GPU causality.",
        "DEEP is sampled Lua execution during F8 and can catch content callbacks/monkey patches.",
        "UNATTRIBUTED slow frames are intentionally left unassigned when evidence is insufficient.",
      },
    }

    mod.log:info(
      "PERF DIAG %.1fs: slow=%d severe=%d unattributed=%d deep=%s",
      diagnostic.duration, diagnostic.slowFrames, diagnostic.severeFrames,
      diagnostic.unattributed, diagnostic.deepAvailable and "on" or "off")
    for i = 1, math.min(10, #rows) do
      local r = rows[i]
      mod.log:info(
        "PERF #%d [%s] %s CPU=%.1f%% STUT=%.1f%% MAX=%.2fms DRAW=%.1f/s DEEP=%.1f%% HOT=%s DEEPHOT=%s",
        i, r.verdict, r.id, r.percent, r.stutterPct, r.maxMs,
        r.drawsPerSec, r.deepPct, tostring(r.hot), tostring(r.deepHot))
    end
    if not exportDiagnosticReport(diagnostic.report) then
      mod.log:warn("Performance report export failed: %s", tostring(exportState.error))
    end
  end

  local function resetProfiler(t)
    frameSamples = {}
    frameSamplePos, frameSampleCount = 1, 0
    profiler.current = {}
    profiler.ranked = {}
    profiler.windowStart = t or now()
    profiler.windowSlowFrames = 0
    profiler.windowSevereFrames = 0
    profiler.windowUnattributed = 0
    profiler.windowStutterWins = {}
    profiler.frameDirect = {}
    profiler.frameDeep = {}
    snapshot.modCpuMsPerSec = 0
    snapshot.modCpuPercent = 0
  end

  local function stopDiagnostic(t)
    if not diagnostic.active then return end
    diagnostic.active = false
    stopDeepSampler()
    buildDiagnosticReport(t or now())
  end

  local function startDiagnostic(t)
    if diagnostic.active then return end
    resetProfiler(t)
    diagnostic.active = true
    diagnostic.started = t
    diagnostic.duration = 0
    diagnostic.totals = {}
    diagnostic.slowFrames = 0
    diagnostic.severeFrames = 0
    diagnostic.unattributed = 0
    diagnostic.stutter = {}
    diagnostic.report = nil
    diagnostic.deepAll = 0
    diagnostic.deepMod = 0
    diagnostic.deep = {}
    diagnostic.deepHotspots = {}
    diagnostic.deepAvailable = false
    diagnostic.deepReason = nil
    diagnostic.frameTimesMs = {}
    diagnostic.slowFrameDetails = {}
    diagnostic.series = {}
    diagnostic.lastSeriesSample = t
    diagnostic.logicStepsStart = logicSteps
    diagnostic.loadedMods, diagnostic.loadOrder = captureLoadedMods()
    diagnostic.environment = captureEnvironment(gameRef)
    diagnostic.captureId = "perf-" .. tostring(math.floor(t * 1000))
    exportState.error = nil
    startDeepSampler()
    mod.log:info("Performance diagnostic started for %.0f seconds", DIAGNOSTIC_SECONDS)
  end

  -- -----------------------------------------------------------------------
  -- Snapshot / input
  -- -----------------------------------------------------------------------
  local function updateSnapshot(game, t)
    if t - lastStatsTime < 0.25 then return end
    lastStatsTime = t

    if love and love.timer and love.timer.getFPS then
      local ok, value = pcall(love.timer.getFPS)
      if ok and type(value) == "number" then snapshot.fps = value end
    end
    snapshot.avgMs, snapshot.worstMs, snapshot.low1 = computeFrameStats()

    if collectgarbage then
      local ok, kb = pcall(collectgarbage, "count")
      if ok and type(kb) == "number" then snapshot.luaMB = kb / 1024 end
    end

    local gs = safeGraphicsStats()
    snapshot.textureMB = (tonumber(gs.texturememory) or 0) / (1024 * 1024)
    snapshot.drawcalls = tonumber(gs.drawcalls) or 0
    snapshot.batched = tonumber(gs.drawcallsbatched) or 0
    snapshot.canvasswitches = tonumber(gs.canvasswitches) or 0
    snapshot.images = tonumber(gs.images) or 0
    snapshot.canvases = tonumber(gs.canvases) or 0
    snapshot.fonts = tonumber(gs.fonts) or 0
    snapshot.shaderswitches = tonumber(gs.shaderswitches) or 0

    if game and game.logicSpeed then
      local ok, speed = pcall(game.logicSpeed, game)
      if ok and type(speed) == "number" then snapshot.speed = speed end
    end
    snapshot.top = activityState(game)
    snapshot.map = mapName(game)

    if diagnostic.active and t - (diagnostic.lastSeriesSample or 0) >= 0.25 then
      diagnostic.lastSeriesSample = t
      diagnostic.series[#diagnostic.series + 1] = {
        t = math.max(0, t - diagnostic.started),
        fps = snapshot.fps,
        frameMs = snapshot.frameMs,
        averageMs = snapshot.avgMs,
        worstRollingMs = snapshot.worstMs,
        onePercentLowRollingFps = snapshot.low1,
        logicPerSecond = logicPerSecond,
        luaMB = snapshot.luaMB,
        textureMB = snapshot.textureMB,
        drawcalls = snapshot.drawcalls,
        batched = snapshot.batched,
        canvasswitches = snapshot.canvasswitches,
        shaderswitches = snapshot.shaderswitches,
        state = snapshot.top,
        map = snapshot.map,
      }
    end
  end

  local function controllerChordDown(button)
    -- Use the engine's logical input state first. This covers Android and
    -- raw/unrecognized controllers that do not expose SDL gamepad names.
    local input = gameRef and gameRef.input
    local logicalSelect, logicalButton = false, false
    if input and input.isDown then
      logicalSelect = input:isDown("select")
      logicalButton = input:isDown(button)
      if logicalSelect and logicalButton then
        controllerMode = true
        return true
      end
    end
    if not (love and love.joystick and love.joystick.getJoysticks) then return false end
    local ok, joysticks = pcall(love.joystick.getJoysticks)
    if not ok or type(joysticks) ~= "table" then return false end
    for _, joystick in ipairs(joysticks) do
      local physicalSelect = logicalSelect
      local okPad, isPad = false, false
      if joystick and joystick.isGamepad then
        okPad, isPad = pcall(function() return joystick:isGamepad() end)
      end
      if okPad and isPad and joystick.isGamepadDown then
        local okHeld, held = pcall(function()
          local name = ({up = "dpup", down = "dpdown", left = "dpleft", right = "dpright"})[button]
          return joystick:isGamepadDown("back")
            and name and joystick:isGamepadDown(name)
        end)
        if okHeld and held then
          controllerMode = true
          return true
        end
      end
      if joystick and joystick.isDown and not physicalSelect then
        for _, index in ipairs({ 7, 9 }) do
          local okHeld, held = pcall(joystick.isDown, joystick, index)
          if okHeld and held then physicalSelect = true break end
        end
      end
      if physicalSelect and joystick then
        local directionHeld = false
        if joystick.getHatCount and joystick.getHat then
          local okCount, count = pcall(joystick.getHatCount, joystick)
          for hat = 1, (okCount and count or 0) do
            local okHat, value = pcall(joystick.getHat, joystick, hat)
            if okHat and type(value) == "string" and (
              value == ({up = "u", down = "d", left = "l", right = "r"})[button]
              or value == ({up = "lu", down = "ld", left = "l", right = "r"})[button]
              or value == ({up = "ru", down = "rd", left = "l", right = "r"})[button]) then
              directionHeld = true
              break
            end
          end
        end
        if not directionHeld and joystick.getAxis then
          local axis = (button == "left" or button == "right") and 1 or 2
          local okAxis, value = pcall(joystick.getAxis, joystick, axis)
          if okAxis and type(value) == "number" then
            directionHeld = (button == "down" and value > 0.5)
              or (button == "up" and value < -0.5)
              or (button == "right" and value > 0.5)
              or (button == "left" and value < -0.5)
          end
        end
        if directionHeld then
          controllerMode = true
          return true
        end
      end
    end
    return false
  end

  local function inputHeldOrQueued(input, button)
    if not input then return false end
    if input.isDown and input:isDown(button) then return true end
    local sources = input.sources and input.sources[button]
    if sources and next(sources) ~= nil then return true end
    for _, queued in ipairs(input.pressQueue or {}) do
      if queued == button then return true end
    end
    return false
  end

  local function updateControllerHotkeys(t)
    local chords = {
      up = "hide", down = "compact", left = "colors_prev", right = "colors_next",
    }
    for button, action in pairs(chords) do
      local queued = padChordPending[button]
      local down = queued or controllerChordDown(button)
      padChordPending[button] = nil
      if queued then
        controllerMode = true
        saveUiState()
      end
      if down and not padChordWasDown[button] then
        if action == "hide" then
          visible = not visible
          saveUiState()
        elseif action == "compact" then
          cycleDisplayMode()
        elseif action == "colors_prev" or action == "colors_next" then
          colorTheme = action == "colors_next"
            and (colorTheme % 5 + 1)
            or ((colorTheme - 2) % 5 + 5) % 5 + 1
          if love and love.filesystem and love.filesystem.write then
            pcall(love.filesystem.write, COLOR_THEME_FILE, tostring(colorTheme))
          end
        end
      end
      padChordWasDown[button] = down
    end
  end

  local function updateHotkeys(t)
    updateControllerHotkeys(t)
    if not (love and love.keyboard and love.keyboard.isDown) then return end

    local f3 = love.keyboard.isDown("f3")
    local f4 = love.keyboard.isDown("f4")
    local f6 = love.keyboard.isDown("f6")
    local f7 = love.keyboard.isDown("f7")
    local f8 = love.keyboard.isDown("f8")
    local f9 = love.keyboard.isDown("f9")
    if f3 or f4 or f6 or f7 or f8 or f9 then
      controllerMode = false
    end
    if f3 and not f3WasDown then
      visible = not visible
      saveUiState()
    end
    f3WasDown = f3

    if f4 and not f4WasDown then
      cycleDisplayMode()
    end
    f4WasDown = f4

    if f6 and not f6WasDown then resetProfiler(t) end
    f6WasDown = f6

    if f7 and not f7WasDown then
      colorTheme = colorTheme % 5 + 1
      if love and love.filesystem and love.filesystem.write then
        pcall(love.filesystem.write, COLOR_THEME_FILE, tostring(colorTheme))
      end
    end
    f7WasDown = f7

    if f8 and not f8WasDown then
      if diagnostic.active then stopDiagnostic(t) else startDiagnostic(t) end
    end
    f8WasDown = f8

    if f9 and not f9WasDown then
      if diagnostic.report then
        if not exportDiagnosticReport(diagnostic.report) then
          mod.log:warn("Performance report export failed: %s", tostring(exportState.error))
        end
      else
        exportState.error = "run an F8 diagnostic first"
      end
    end
    f9WasDown = f9
  end

  -- Fixed-step counter used by the visible monitor and diagnostics.
  mod.hooks:wrap("input.step", function(nextFn, game, dt)
    -- The directional chord is a monitor shortcut, not player movement.
    -- Remove its queued edge before the engine promotes it; clearing state
    -- only after nextFn was too late for repeated D-pad presses.
    local input = game and game.input
    if input and input.isDown and input.state then
      if inputHeldOrQueued(input, "select") then
        for _, direction in ipairs({ "up", "down", "left", "right" }) do
          local queued = false
          for _, btn in ipairs(input.pressQueue or {}) do
            if btn == direction then queued = true break end
          end
          if inputHeldOrQueued(input, direction) or queued then
            padChordPending[direction] = true
            input.state[direction] = false
            if input.pressed then input.pressed[direction] = nil end
            if input.pressQueue then
              for i = #input.pressQueue, 1, -1 do
                if input.pressQueue[i] == direction then
                  table.remove(input.pressQueue, i)
                end
              end
            end
          end
        end
      end
    end
    local result = nextFn(game, dt)
    -- The engine promotes queued controller input inside nextFn.  Some
    -- handhelds, including the R36H, expose Down only at that point, so
    -- mirror the same pressed/held state the player movement code reads.
    if input and input.isDown and inputHeldOrQueued(input, "select") then
      for _, direction in ipairs({ "up", "down", "left", "right" }) do
        local pressed = input.pressed and input.pressed[direction]
        if pressed or input:isDown(direction) then
          padChordPending[direction] = true
          if input.state then input.state[direction] = false end
          if input.pressed then input.pressed[direction] = nil end
        end
      end
    end
    if visible then
      logicSteps = logicSteps + 1
      logicWindowSteps = logicWindowSteps + 1
      local t = now()
      local elapsed = t - lastSecondTime
      if elapsed >= 1.0 then
        logicPerSecond = logicWindowSteps / elapsed
        logicWindowSteps = 0
        lastSecondTime = t
      end
    end
    return result
  end, 900)

  mod.events:on("game.ready", function(ev)
    gameRef = ev and ev.game or nil
    local t = now()
    lastHudTime = t
    lastStatsTime = 0
    lastSecondTime = t
    profiler.windowStart = t
    rebuildFunctionProvenance()
    scanRuntime()
    mod.log:info(
      "Performance Monitor %s ready (%d hooks, %d events instrumented)",
      VERSION, profiler.instrumentedHooks, profiler.instrumentedEvents)
  end, 900)

  -- -----------------------------------------------------------------------
  -- HUD
  -- -----------------------------------------------------------------------
  local function fmtInt(v)
    return tostring(math.floor((tonumber(v) or 0) + 0.5))
  end

  local function shortId(s, n)
    s = tostring(s or "?")
    n = n or 22
    if #s <= n then return s end
    return s:sub(1, n - 1) .. "~"
  end

  local function currentRows()
    if diagnostic.report then return diagnostic.report.modsImpact or {}, true end
    return profiler.ranked, false
  end

  local function drawPanel(game, viewport, frameMs)
    if not (love and love.graphics) then return end
    local t = now()

    -- Hotkeys remain live while hidden; all actual monitoring work stops.
    updateHotkeys(t)
    if not visible then
      if diagnostic.active then stopDiagnostic(t) end
      profiler.frameDirect = {}
      profiler.frameDeep = {}
      return
    end
    if t - profiler.lastScan >= 0.50 then
      profiler.lastScan = t
      scanRuntime()
    end
    if diagnostic.active and t - diagnostic.started >= DIAGNOSTIC_SECONDS then
      stopDiagnostic(t)
    end

    closeProfilerWindow(t)
    updateSnapshot(game, t)

    if not visible then return end

    local lines = {
      ("FPS   %s | %5.2f ms"):format(fmtInt(snapshot.fps), frameMs),
      ("LOW   %s%% | AVG %5.2f ms"):format(fmtInt(snapshot.low1), snapshot.avgMs),
      ("LUA   %5.1f MB | TEX %5.1f MB"):format(snapshot.luaMB, snapshot.textureMB),
      ("DRAW  %4d | BATCH %4d"):format(snapshot.drawcalls, snapshot.batched),
      ("LOGIC %5.1f/s | %s"):format(logicPerSecond, shortId(snapshot.top, 18)),
    }

    if diagnostic.active then
      lines[#lines + 1] = ("DIAG %.1f/%.1fs  DEEP %s  slow>%0.1fms %d"):format(
        t - diagnostic.started, DIAGNOSTIC_SECONDS,
        diagnostic.deepAvailable and "ON" or "OFF", SLOW_MS, diagnostic.slowFrames)
    elseif diagnostic.report then
      local r = diagnostic.report
      local c = r.capture or {}
      local attr = (c.slowFrames or 0) > 0
        and (((c.slowFrames or 0) - (c.unattributedSlowFrames or 0)) * 100 / c.slowFrames) or 0
      lines[#lines + 1] = ("FROZEN DIAG %.1fs  slow %d severe %d  attributed %.0f%%"):format(
        r.capture and r.capture.durationSeconds or r.duration or 0,
        r.capture and r.capture.slowFrames or r.slowFrames or 0,
        r.capture and r.capture.severeFrames or r.severeFrames or 0, attr)
      if exportState.relativeJson then
        lines[#lines + 1] = "EXPORT: " .. tostring(exportState.relativeJson)
      elseif exportState.error then
        lines[#lines + 1] = "EXPORT ERROR: " .. shortId(exportState.error, 70)
      end
    end

    if detailed then
      lines[#lines + 1] = ("Avg %.2f  Worst %.2f ms  Lua %.1f MB  Texture %.1f MB"):format(
        snapshot.avgMs, snapshot.worstMs, snapshot.luaMB, snapshot.textureMB)
      lines[#lines + 1] = ("Draw %d  Batched %d  Canvas %d  Shader %d  State %s"):format(
        snapshot.drawcalls, snapshot.batched, snapshot.canvasswitches,
        snapshot.shaderswitches, snapshot.top)
      lines[#lines + 1] = "--- MOD FLUIDITY IMPACT ---"

      local rows, frozen = currentRows()
      if #rows == 0 then
        lines[#lines + 1] = diagnostic.active and "collecting diagnostic samples..." or "waiting for profiler sample..."
      else
        for i = 1, math.min(6, #rows) do
          local r = rows[i]
          local verdict = frozen and (r.verdict or "-") or "LIVE"
          local deepPct = frozen and (r.deepPct or 0) or 0
          lines[#lines + 1] = ("%d %-4s %-20s CPU%5.1f%% STUT%4.0f%% MAX%5.2f D%5.0f/s S%4.0f%%"):format(
            i, verdict, shortId(r.id, 20), r.percent or 0, r.stutterPct or 0,
            r.maxMs or 0, r.drawsPerSec or 0, deepPct)
          if frozen then
            local hot = r.deepPct >= 5 and r.deepHot ~= "-" and ("deep " .. tostring(r.deepHot))
              or tostring(r.hot or "-")
            lines[#lines + 1] = "   hot: " .. shortId(hot, 72)
          end
        end
      end

      if diagnostic.report then
        local r = diagnostic.report
        local c = r.capture or {}
        local deepCoverage = (c.deepSamplesAll or 0) > 0
          and ((c.deepSamplesAttributedToMods or 0) * 100 / c.deepSamplesAll) or 0
        lines[#lines + 1] = ("Slow unattrib %d/%d  Deep mod coverage %.1f%%"):format(
          c.unattributedSlowFrames or 0, c.slowFrames or 0, deepCoverage)
        if not c.deepAvailable then
          lines[#lines + 1] = "Deep sampler unavailable: " .. tostring(c.deepReason or "unknown")
        end
      else
        lines[#lines + 1] = "CPU=exclusive callback | STUT=slow-frame wins | D=draws/s | S=deep sample%"
      end
      lines[#lines + 1] = "F3 hide  F4 compact  F6 reset  F8 diagnostic  F9 export"
    else
      local rows, frozen = currentRows()
      local top = rows[1]
      local culprit = top and ("%s CPU %.1f%% STUT %.0f%% MAX %.2fms"):format(
        shortId(top.id, 18), top.percent or 0, top.stutterPct or 0, top.maxMs or 0)
        or "sampling..."
      lines[#lines + 1] = "Top: " .. culprit
      lines[#lines + 1] = frozen and "F8 new diagnostic  F9 export  F4 details  F3 hide"
        or "F8 diagnose  F4 details  F3 hide"
    end

    local pushed = love.graphics.push and pcall(love.graphics.push, "all")
    local screenW, screenH = love.graphics.getDimensions()
    local smallScreen = screenW <= 640 or screenH <= 480
    if love.graphics.newFont and not overlayFont then
      overlayFont = love.graphics.newFont(12)
      if overlayFont.setFilter then pcall(overlayFont.setFilter, overlayFont, "linear", "linear") end
    end
    if love.graphics.newFont and not controllerBindFont then
      controllerBindFont = love.graphics.newFont(smallScreen and 11 or 11)
      if controllerBindFont.setFilter then
        pcall(controllerBindFont.setFilter, controllerBindFont, "linear", "linear")
      end
    end
    if overlayFont and love.graphics.setFont then love.graphics.setFont(overlayFont) end
    local font = overlayFont or (love.graphics.getFont and love.graphics.getFont() or nil)
    local lineH = font and font.getHeight and font:getHeight() or 12

    do
      local panelW = extremeCompact and 230 or 350
      local widthFit = (screenW - 24) / panelW
      -- Keep the pixel font crisp on handhelds.  A 640x480 display can fit
      -- the compact dashboard at native scale; fractional scaling makes the
      -- font look blurred on the R36H panel.
      local uiScale = math.max(0.82, math.min(1.0, widthFit,
        screenW / 640, screenH / 480))
      love.graphics.scale(uiScale, uiScale)
      local palettes = {
        {panel = {0.025, 0.035, 0.075, 0.98}, header = {0.18, 0.75, 0.98, 1}, accent = {0.55, 0.88, 1.00, 1}, section = {0.12, 0.16, 0.28, 1}, card = {0.06, 0.08, 0.16, 1}},
        {panel = {0.075, 0.025, 0.095, 0.98}, header = {0.78, 0.28, 0.92, 1}, accent = {0.92, 0.55, 1.00, 1}, section = {0.28, 0.12, 0.34, 1}, card = {0.16, 0.06, 0.20, 1}},
        {panel = {0.025, 0.085, 0.075, 0.98}, header = {0.16, 0.82, 0.52, 1}, accent = {0.45, 1.00, 0.72, 1}, section = {0.10, 0.28, 0.22, 1}, card = {0.05, 0.16, 0.13, 1}},
        {panel = {0.09, 0.055, 0.015, 0.98}, header = {0.98, 0.55, 0.12, 1}, accent = {1.00, 0.82, 0.38, 1}, section = {0.30, 0.20, 0.06, 1}, card = {0.18, 0.11, 0.03, 1}},
        {panel = {0.10, 0.018, 0.025, 0.98}, header = {0.96, 0.20, 0.28, 1}, accent = {1.00, 0.48, 0.52, 1}, section = {0.32, 0.07, 0.09, 1}, card = {0.19, 0.035, 0.05, 1}},
      }
      local palette = palettes[colorTheme] or palettes[1]
      local tableRows = currentRows()
      local rowCount = math.min(5, #tableRows)
      local headerH, statsH, chartH, engineH, statusH = 30, 38, 78, 127, 0
      local tableH, footerH = 22 + math.max(1, rowCount) * 19, 72
      -- `detailed` is the user's explicit compact/expand choice.  Do not
      -- override it on handhelds: that made Select+Down appear broken by
      -- forcing the R36H back into compact mode immediately.
      local compact = not detailed
      local panelH = extremeCompact and (headerH + statsH + 8)
        or (compact and (headerH + statsH + chartH + 39)
        or (headerH + statsH + chartH + engineH + statusH + tableH + footerH + 18)
        )
      local x, y = 12 / uiScale, 12 / uiScale

      local function textWidth(s)
        local activeFont = love.graphics.getFont and love.graphics.getFont() or font
        return (activeFont and activeFont.getWidth) and activeFont:getWidth(s) or (#s * 7)
      end
      local function shadowText(s, tx, ty, color)
        if not smallScreen then
          love.graphics.setColor(0, 0, 0, 0.95)
          love.graphics.print(s, tx + 1, ty + 1)
        end
        love.graphics.setColor(color[1], color[2], color[3], color[4] or 1)
        love.graphics.print(s, tx, ty)
      end
      local bindKeyColor = palette.accent
      local bindLabelColor = {0.78, 0.82, 0.94, 1}
      local function gauge(label, value, maximum, suffix, gy, color)
        local barX, barW = x + 88, panelW - 105
        local amount = math.max(0, math.min(1, (tonumber(value) or 0) / maximum))
        shadowText(label, x + 12, gy, {0.84, 0.88, 0.98, 1})
        love.graphics.setColor(palette.card[1], palette.card[2], palette.card[3], palette.card[4])
        love.graphics.rectangle("fill", barX, gy + 2, barW, 10, 4, 4)
        love.graphics.setColor(color[1], color[2], color[3], 1)
        love.graphics.rectangle("fill", barX, gy + 2, barW * amount, 10, 4, 4)
        local valueText = string.format("%s%s", fmtInt(value), suffix)
        shadowText(valueText, x + panelW - 12 - textWidth(valueText), gy - 1, {1, 1, 1, 1})
      end

      love.graphics.setColor(palette.panel[1], palette.panel[2], palette.panel[3], palette.panel[4])
      love.graphics.rectangle("fill", x, y, panelW, panelH, 10, 10)
      love.graphics.setColor(palette.header[1], palette.header[2], palette.header[3], palette.header[4])
      love.graphics.rectangle("fill", x, y, panelW, headerH, 10, 10)
      shadowText("PERFORMANCE", x + 12, y + 6, {1, 1, 1, 1})

      local statsY = y + headerH + 5
      local function numberCard(label, value, suffix, cardX, color)
        love.graphics.setColor(palette.card[1], palette.card[2], palette.card[3], palette.card[4])
        love.graphics.rectangle("fill", cardX, statsY, 103, 29, 4, 4)
        shadowText(label, cardX + 7, statsY + 3, {0.68, 0.76, 0.92, 1})
        local valueText = tostring(value) .. suffix
        shadowText(valueText, cardX + 103 - 7 - textWidth(valueText), statsY + 2, color)
      end
      numberCard("FPS", fmtInt(snapshot.fps), "", x + 8, {0.35, 1.00, 0.62, 1})
      if not extremeCompact then
        numberCard("LOW", fmtInt(snapshot.low1), "", x + 119, {0.38, 0.84, 1.00, 1})
      end
      numberCard("LUA", string.format("%.1f", snapshot.luaMB), " MB",
        x + (extremeCompact and 119 or 230), {0.72, 0.56, 1.00, 1})

      if extremeCompact then
        if pushed and love.graphics.pop then love.graphics.pop()
        else love.graphics.setColor(1, 1, 1, 1) end
        return
      end

      local chartY = statsY + statsH
      local chartX, chartW, chartBoxH = x + 8, panelW - 16, 51
      shadowText("FRAMETIME", chartX + 6, chartY + 2, {0.55, 0.88, 1, 1})
      local frameLabel = string.format("CURRENT %.2f ms", frameMs)
      shadowText(frameLabel, chartX + chartW - 6 - textWidth(frameLabel), chartY + 2, {1, 0.84, 0.42, 1})
      love.graphics.setColor(0.035, 0.05, 0.11, 1)
      love.graphics.rectangle("fill", chartX, chartY + 19, chartW, chartBoxH, 4, 4)
      love.graphics.setColor(0.22, 0.28, 0.42, 0.8)
      love.graphics.line(chartX, chartY + 19 + chartBoxH * 0.5, chartX + chartW, chartY + 19 + chartBoxH * 0.5)
      love.graphics.setColor(palette.accent[1], palette.accent[2], palette.accent[3], palette.accent[4])
      local previousX, previousY
      if frameSampleCount > 0 then
        for i = 1, frameSampleCount do
          local sampleIndex = (frameSamplePos - frameSampleCount - 1 + i) % frameSampleMax + 1
          local sample = math.max(0, math.min(50, frameSamples[sampleIndex] or 0))
          local px = chartX + (i - 1) * (chartW - 2) / math.max(1, frameSampleCount - 1) + 1
          local py = chartY + 19 + chartBoxH - (sample / 50) * chartBoxH
          if previousX then love.graphics.line(previousX, previousY, px, py) end
          previousX, previousY = px, py
        end
      end
      local bottomLabel = "BOTTOM 0 ms"
      shadowText(bottomLabel, chartX + chartW - 8 - textWidth(bottomLabel), chartY + 20, {0.50, 0.58, 0.72, 1})
      local scaleLabel = "MAX 50 ms"
      shadowText(scaleLabel, chartX + chartW - 8 - textWidth(scaleLabel), chartY + 34, {0.50, 0.58, 0.72, 1})

      if compact then
        local compactBindY = y + headerH + statsH + 85
        local function compactBindCard(key, label, cardX)
          love.graphics.setColor(palette.card[1], palette.card[2], palette.card[3], palette.card[4])
          love.graphics.rectangle("fill", cardX, compactBindY, 103, 18, 3, 3)
          shadowText(key, cardX + 6, compactBindY + 3, bindKeyColor)
          local labelRight = controllerMode and 100 or 97
          shadowText(label, cardX + labelRight - textWidth(label), compactBindY + 3, bindLabelColor)
        end
        if controllerMode then
          if controllerBindFont and love.graphics.setFont then love.graphics.setFont(controllerBindFont) end
          compactBindCard("SEL+U", "HIDE", x + 8)
          compactBindCard("SEL+D", "EXPAND", x + 119)
          compactBindCard("SEL+L/R", "COLORS", x + 230)
          if font and love.graphics.setFont then love.graphics.setFont(font) end
        else
          compactBindCard("F3", "HIDE", x + 8)
          compactBindCard("F4", "EXPAND", x + 119)
          compactBindCard("F7", "COLORS", x + 230)
        end
        if pushed and love.graphics.pop then love.graphics.pop()
        else love.graphics.setColor(1, 1, 1, 1) end
        return
      end

      local engineY = chartY + chartH + 4
      local function engineCard(label, value, cardX, cardY, cardW, color)
        love.graphics.setColor(palette.card[1], palette.card[2], palette.card[3], palette.card[4])
        love.graphics.rectangle("fill", cardX, cardY, cardW, 18, 3, 3)
        shadowText(label, cardX + 6, cardY + 2, {0.55, 0.64, 0.82, 1})
        shadowText(value, cardX + cardW - 6 - textWidth(value), cardY + 2, color or {0.88, 0.92, 1, 1})
      end
      shadowText("ENGINE", x + 10, engineY + 1, {0.55, 0.88, 1, 1})
      engineCard("TEX", string.format("%.1f MB", snapshot.textureMB), x + 8, engineY + 18, 103, {0.82, 0.90, 1, 1})
      engineCard("DRAW", tostring(snapshot.drawcalls), x + 119, engineY + 18, 103, {0.82, 0.90, 1, 1})
      engineCard("BATCH", tostring(snapshot.batched), x + 230, engineY + 18, 103, {0.82, 0.90, 1, 1})
      engineCard("CANVAS", tostring(snapshot.canvasswitches), x + 8, engineY + 39, 103, {0.78, 0.84, 0.96, 1})
      engineCard("SHADER", tostring(snapshot.shaderswitches), x + 119, engineY + 39, 103, {0.78, 0.84, 0.96, 1})
      engineCard("LOGIC", string.format("%.1f/s", logicPerSecond), x + 230, engineY + 39, 103, {0.78, 0.84, 0.96, 1})
      engineCard("AVG", string.format("%.1f ms", snapshot.avgMs), x + 8, engineY + 60, 158, {0.78, 0.84, 0.96, 1})
      engineCard("WORST", string.format("%.1f ms", snapshot.worstMs), x + 174, engineY + 60, 159, {1.00, 0.72, 0.62, 1})
      engineCard("STATE", shortId(snapshot.top, 22), x + 8, engineY + 81, 325, {0.70, 0.88, 1, 1})
      engineCard("MAP", shortId(snapshot.map, 22), x + 8, engineY + 102, 325, {0.70, 0.88, 1, 1})

      local tableY = engineY + engineH + 2
      love.graphics.setColor(palette.section[1], palette.section[2], palette.section[3], palette.section[4])
      love.graphics.rectangle("fill", x + 8, tableY, panelW - 16, 20, 3, 3)
      shadowText("MODS", x + 14, tableY + 4, {0.55, 0.88, 1, 1})
      shadowText("CPU", x + 150, tableY + 4, {0.70, 0.76, 0.90, 1})
      shadowText("STUT", x + 205, tableY + 4, {0.70, 0.76, 0.90, 1})
      shadowText("MAX", x + 260, tableY + 4, {0.70, 0.76, 0.90, 1})
      shadowText("DRAW", x + 304, tableY + 4, {0.70, 0.76, 0.90, 1})

      local rowY = tableY + 22
      if rowCount == 0 then
        shadowText(diagnostic.active and "collecting diagnostic samples..." or "no mod callback data yet", x + 14, rowY + 2, {0.82, 0.84, 0.92, 1})
      else
        for i = 1, rowCount do
          local r = tableRows[i]
          if i % 2 == 1 then
            love.graphics.setColor(0.045, 0.06, 0.12, 1)
            love.graphics.rectangle("fill", x + 8, rowY - 2, panelW - 16, 19)
          end
          shadowText(shortId(r.id, 20), x + 14, rowY, {0.95, 0.95, 1, 1})
          shadowText(string.format("%4.1f%%", r.percent or 0), x + 146, rowY, {0.70, 1, 0.78, 1})
          shadowText(string.format("%4.0f%%", r.stutterPct or 0), x + 201, rowY, {1, 0.84, 0.45, 1})
          shadowText(string.format("%4.1f", r.maxMs or 0), x + 258, rowY, {1, 0.75, 0.75, 1})
          shadowText(string.format("%4.0f", r.drawsPerSec or 0), x + 304, rowY, {0.75, 0.85, 1, 1})
          rowY = rowY + 19
        end
      end
      local function bindCard(key, label, cardX, cardY, cardW)
        love.graphics.setColor(palette.card[1], palette.card[2], palette.card[3], palette.card[4])
        love.graphics.rectangle("fill", cardX, cardY, cardW, 18, 3, 3)
        shadowText(key, cardX + 6, cardY + 3, bindKeyColor)
        local labelRight = controllerMode and cardW - 3 or cardW - 6
        shadowText(label, cardX + labelRight - textWidth(label), cardY + 3, bindLabelColor)
      end
      local bindY = y + panelH - 70
      if controllerMode then
        if controllerBindFont and love.graphics.setFont then love.graphics.setFont(controllerBindFont) end
        bindCard("SEL+U", "HIDE", x + 8, bindY, 103)
        bindCard("SEL+D", "COMPACT", x + 119, bindY, 103)
        bindCard("SEL+L/R", "COLORS", x + 230, bindY, 103)
        if font and love.graphics.setFont then love.graphics.setFont(font) end
      else
        bindCard("F3", "HIDE", x + 8, bindY, 103)
        bindCard("F4", "COMPACT", x + 119, bindY, 103)
        bindCard("F5", "RELOAD", x + 230, bindY, 103)
        bindCard("F6", "RESET", x + 8, bindY + 20, 103)
        bindCard("F7", "COLORS", x + 119, bindY + 20, 103)
        bindCard("F8", "DIAG", x + 230, bindY + 20, 103)
        bindCard("F9", "EXPORT", x + 8, bindY + 40, 103)
      end
      if pushed and love.graphics.pop then love.graphics.pop()
      else love.graphics.setColor(1, 1, 1, 1) end
      return
    end

  end

  -- Outermost HUD wrapper.  Calling next first guarantees every downstream
  -- render.hud mod has finished and its instrumented callback has been
  -- recorded before we classify this frame or display its row.
  mod.hooks:wrap("render.hud", function(nextFn, game, viewport)
    local result = nextFn(game, viewport)
    local t = now()
    local frameMs = lastHudTime and ((t - lastHudTime) * 1000) or TARGET_MS
    lastHudTime = t
    if visible and frameMs > 0 and frameMs < 1000 then
      snapshot.frameMs = frameMs
      pushFrameSample(frameMs)
      finalizeFrame(frameMs)
    else
      -- Ignore focus-loss / debugger pauses rather than charging the next
      -- real frame for callbacks accumulated across a multi-second gap.
      profiler.frameDirect = {}
      profiler.frameDeep = {}
    end
    drawPanel(game or gameRef, viewport, frameMs)
    return result
  end, 100000)

  mod.exports.getSnapshot = function()
    local copy = {}
    for k, v in pairs(snapshot) do copy[k] = v end
    copy.logicPerSecond = logicPerSecond
    copy.logicSteps = logicSteps
    copy.visible = visible
    copy.detailed = detailed
    copy.extremeCompact = extremeCompact
    copy.slowThresholdMs = SLOW_MS
    copy.mods = {}
    for i, r in ipairs(profiler.ranked) do
      local row = {}
      for k, v in pairs(r) do row[k] = v end
      copy.mods[i] = row
    end
    return copy
  end

  mod.exports.getDiagnosticReport = function()
    return diagnostic.report
  end

  mod.exports.exportDiagnosticReport = function()
    if not diagnostic.report then return false, "no completed diagnostic report" end
    local ok = exportDiagnosticReport(diagnostic.report)
    return ok, ok and exportState.relativeJson or exportState.error
  end

  mod.exports.getExportState = function()
    local out = {}
    for k, v in pairs(exportState) do out[k] = v end
    return out
  end
end
