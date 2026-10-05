--------------------------------------------------------------------------------
-- BanditSpawner.lua
-- Per-player F10 radio command that spawns a bandit group N nautical miles
-- directly ahead of the clicking player's aircraft, pointed back at the player,
-- at a randomized altitude / speed around configurable defaults.
--
-- Two spawn modes per radio item (mix and match in cfg.spawns):
--   mode = "clone" : duplicates a LATE ACTIVATION group placed in the ME
--                    (keeps unit types, count, liveries, callsigns, and the
--                    payload you gave it in the editor -- so build the template
--                    with external tanks + gun and you're done).
--   mode = "build" : spawns a fresh group of a chosen airframe + count, with a
--                    clean loadout (empty pylons + 100% gun ammo, no missiles),
--                    or a payload copied from an ME "donor" group via payload_from.
--
-- Afterburner use is prohibited via AI.Option.Air.id.PROHIBIT_AB.
-- By default bandits join the coalition OPPOSITE the clicking player and get an
-- "Engage Air" en-route task, so they actively attack your side.
--
-- AO mode (map-referenced, multiplayer-friendly): give any spawn def an "ao"
-- field (trigger zone name, or ao = { x = ..., z = ... }) plus bearing_deg and
-- distance_nm -- the bandits spawn on that bearing FROM the reference point,
-- that far out, and fly inbound. Every client in MP gets the same menu and
-- the same fixed AO geometry, instead of 'ahead of whoever clicked'.
--
-- INSTALL:
--   Mission Editor -> Triggers -> ONCE (time more 0) -> DO SCRIPT FILE ->
--   select this file. (Or paste the whole file into a DO SCRIPT action.)
--
-- LOADOUTS: build them visually in the ME on "donor" groups (see below) and
-- reference them with payload_from on the spawn def -- no CLSIDs anywhere.
-- Without payload_from, build-mode aircraft spawn with clean pylons (internal
-- fuel + 100% gun ammo) and clones keep whatever payload their ME template
-- carries.
--
-- ALTERNATIVE WITHOUT CLSIDs (recommended): "donor" groups. Place a 1-plane
-- late-activation group in the ME with the loadout built visually in the
-- editor payload window (clean = guns only, Sidewinders only = IR+guns,
-- full AA + tanks = radar+IR+guns+tanks, ...) and set payload_from =
-- "DONOR GROUP NAME" on the spawn def. The pylon table is copied at runtime.
--------------------------------------------------------------------------------

BanditSpawner = {}

--=============================================================================
-- Behavior & ROE mapping
local BehaviorMap = {
  Intercept = "Intercept",
  Drone     = "Drone",
}

local ROEMap = {
  ["Weapon Free"]  = AI.Option.Air.val.ROE.WEAPON_FREE,
  ["Weapon Tight"] = AI.Option.Air.val.ROE.WEAPON_TIGHT,
  ["Weapon Hold"]  = AI.Option.Air.val.ROE.WEAPON_HOLD,
}
-- CONFIG
--=============================================================================
BanditSpawner.cfg = {

  -- spawn geometry (all can be overridden per-entry in cfg.spawns)
  distance_nm         = 10,     -- how far in front of the player
  bearing_jitter_deg  = 0,      -- random +/- jitter on spawn bearing (0 = dead ahead)

  -- randomized flight parameters (can be overridden per-entry in cfg.spawns)
  alt_ft              = 10000,  -- default altitude, feet MSL
  alt_var_ft          = 2000,   -- random +/- around alt_ft
  min_alt_agl_ft      = 1000,   -- floor: never spawn lower than this above terrain
  speed_kts           = 450,    -- default speed, knots
  speed_var_kts       = 75,     -- random +/- around speed_kts

  skill               = "High",     -- AI skill: "Average" | "Good" | "High" | "Excellent" | "Ace" (build mode; case-insensitive)

  -- ownership of spawned bandits:
  --   "opposite" (default) = a country from the mission's own country list
  --     that sits on the coalition HOSTILE to whoever clicked the radio item
  --     (blue player -> red bandits, red player -> blue bandits).
  --   a number = force one country, e.g. country.id.RUSSIA, country.id.USA,
  --     country.id.CJTF_RED / country.id.CJTF_BLUE
  country             = "opposite",

  -- behavior
  prohibit_ab         = true,   -- AI forbidden from using afterburner
  guns_full           = true,   -- always give 100% gun ammunition
  no_jettison         = true,   -- AI may not jettison external tanks/weapons (keeps the payload you gave them)
  engage_hostile_air  = true,   -- "Engage Air" en-route task: actively attack enemy aircraft
  attack_on_spawn     = true,   -- add 'Attack Group' task targeting the spawning player's group (ignored in AO mode)
  task                = "Intercept", -- group mission task for ALL spawns ("CAP" | "Intercept" | "Escort" ...); overrides the template's task in clone mode too
  behavior            = "Intercept", -- default behavior: "Intercept" or "Drone"
  loiter_at_end       = true,     -- Orbit task on the last waypoint so bandits stay on station near the fight
  allow_rtb           = false,  -- bandits never RTB on bingo fuel or winchester; they stay and fight

  -- ROE & Behavior Options
  roe_options         = { "Weapon Free", "Weapon Tight", "Weapon Hold" },
  behavior_options    = { "Intercept", "Drone" },
  default_roe         = "Weapon Free",
  default_behavior    = "Intercept",
  -- spam control
  cooldown_sec        = 5,      -- per player group
  max_active          = 4,      -- max simultaneously alive spawned bandit groups (0 = unlimited)
  allow_despawn       = true,   -- adds a "remove all spawned bandits" radio item
  despawn_label       = "Remove all spawned bandits",
  group_prefix        = "BNDT-",

  menu_name           = "Bandit Spawner",
  -- limit radio menu to specific player groups (exact group names).
  -- nil or empty table = menu available to every player group.
  player_groups       = nil,    -- e.g. { "Viper-1", "Hornet-1" }

  -- nested menu distances (nautical miles). nil or empty = flat menu.
  -- a plain number = exact distance; a table = randomized range:
  --   { label = "...", dist_nm = mid, dist_var_nm = half-range }
  spawn_distances_nm  = {
    { label = "5-10 nm",  dist_nm = 7.5, dist_var_nm = 2.5 },
    { label = "20-40 nm", dist_nm = 30,  dist_var_nm = 10 },
  },

  -- nested menu bearing modes. nil or empty = flat menu.
  -- spawn_offset_deg  = bearing from the player to the bandit spawn point.
  -- heading_offset_deg = bandit nose direction relative to the player's heading.
  bearing_modes = {
    { label = "Hot",           spawn_offset_deg = 0,   heading_offset_deg = 180 },
    { label = "Cold",          spawn_offset_deg = 0,   heading_offset_deg = 0 },
    { label = "Flanking",      spawn_offset_deg = 90,  heading_offset_deg = 90,  randomize_sign = true },
    { label = "Offset Toward", spawn_offset_deg = 45,  heading_offset_deg = 135, randomize_sign = true },
    { label = "Offset Away",   spawn_offset_deg = 45,  heading_offset_deg = 45,  randomize_sign = true },
  },

  -- nested menu altitude blocks (feet MSL). nil or empty = classic randomized band.
  -- co_altitude = true matches the requesting player's current altitude; the other
  -- entries randomize inside the block: alt_ft +/- alt_var_ft.
  altitude_modes = {
    { label = "Co-altitude", co_altitude = true },
    { label = "5-10k ft",  alt_ft = 7500,  alt_var_ft = 2500 },
    { label = "12-20k ft", alt_ft = 16000, alt_var_ft = 4000 },
  },

  -- (no CLSID tables needed: loadouts come from donor groups via payload_from,
  --  see the examples in cfg.spawns below)

  -- true = strip cloned template aircraft to clean pylons + full gun.
  -- false (default) = clones keep their ME payload (set it on the template).
  -- payload_from on a spawn def overrides this for matching types either way.
  override_clone_payload = false,

  -- Radio items. Optional per-entry overrides: distance_nm, distance_var_nm, bearing_deg/jitter_deg,
  -- alt_ft, alt_var_ft, speed_kts, speed_var_kts, skill, count, template, airframe,
  -- ao, payload_from.
  spawns = {
    {
      label    = "Bandit from template (BANDIT-TPL)",
      mode     = "clone",
      template = "BANDIT-TPL",   -- exact group name of a LATE ACTIVATION group in the ME
      -- NOTE: the template group's own task is ignored -- spawned clones get cfg.task
      -- (default "CAP"), or a per-entry task = "..." override.
    },
    {
      label    = "1x MiG-21 (guns only)",
      mode     = "build",
      airframe = "MiG-21Bis",       -- unit type name
      count    = 1,
    },
    {
      label    = "1x C-101CC (guns only)",
      mode     = "build",
      airframe = "C-101CC",       -- unit type name
      count    = 1,
      payload_from = "DONOR C-101CC"
    },
    -- AO mode (multiplayer): fixed reference + bearing/distance, works for both
    -- mode = "clone" and mode = "build":
    {
      label       = "2x MiG-21 inbound to the AO",
      mode        = "build",
      airframe    = "MiG-21Bis",
      count       = 2,
      ao          = "AO",          -- trigger zone named "AO" in the ME, or ao = { x = ..., z = ... }
      bearing_deg = 250,           -- spawn on this bearing FROM the AO (250 = from the WSW)
      distance_nm = 40,            -- ... this far out, then run inbound
    },
    -- AO mode with RAW MAP COORDS instead of a trigger zone (no ME zone needed).
    -- x = north, z = east, in meters. Get them by placing a temporary zone/unit
    -- where you want the fight and reading its x/y from the saved mission file
    -- (y in the mission file = this script's z).
    {
      label       = "Bandit template to a fixed point",
      mode        = "clone",
      template    = "BANDIT-TPL",
      ao          = { x = -124000, z = 88000 },  -- example coords, pick your own
      bearing_deg = 90,           -- spawn east of the point, run westbound in
      distance_nm = 25,
    },
    -- GENERIC LOADOUTS VIA "DONOR" GROUPS (no CLSIDs): place 1-plane late-
    -- activation groups in the ME with the loadout built in the editor payload
    -- window, then point payload_from at the donor's group name. For mixed-type
    -- clone groups it can also be a table: payload_from = { ["F-5E-3"] = "DONOR A", ... }
    -- NOTE: airframe = the unit type as written in YOUR mission file (open the .miz
    -- as a zip, read unit.type in the "mission" file). Current builds write the Viper
    -- as "F-16C bl.50"; the old string "F-16C_50" still spawns via an alias, but donor
    -- matching follows the mission file (single-type donors auto-correct a mismatch).
    { label = "2x F-16C guns only",       mode = "build", airframe = "F-16C bl.50", count = 2 },
    { label = "2x F-16C IR + guns",       mode = "build", airframe = "F-16C bl.50", count = 2, payload_from = "DONOR F16 IR" },
    { label = "2x F-16C radar+IR + guns", mode = "build", airframe = "F-16C bl.50", count = 2, payload_from = "DONOR F16 RIR" },
    {
      label    = "WW2-BANDIT",
      mode     = "clone",
      template = "WW2-BANDIT",   -- exact group name of a LATE ACTIVATION group in the ME
    },
    {
      label    = "1x Drone (Straight Line)",
      mode     = "build",
      airframe = "MiG-21Bis",
      count    = 1,
      behavior = "Drone",
    }
  },
}

--=============================================================================
-- INTERNALS (no need to touch below here)
--=============================================================================
local FTS  = BanditSpawner  -- shorthand
local FT2M, NM2M, KT2MS = 0.3048, 1852, 0.514444
local M2FT, MS2KT       = 1 / 0.3048, 1 / 0.514444

--=============================================================================
-- NAMESPACES
--=============================================================================
FTS._state = { hasMenu = {}, lastSpawn = {}, active = {}, spawnCounter = 0 }
FTS.Util      = {}
FTS.Geo       = {}
FTS.Payload     = {}
FTS.Template    = {}
FTS.GroupBuilder = {}
FTS.Spawn       = {}
FTS.Menu        = {}

-- legacy public state aliases kept for backwards compatibility
FTS._hasMenu      = FTS._state.hasMenu
FTS._lastSpawn    = FTS._state.lastSpawn
FTS._active       = FTS._state.active
FTS._spawnCounter = FTS._state.spawnCounter

--=============================================================================
-- CONSTANTS
--=============================================================================
local C = {
  ROUTE_END_DISTANCE_M          = 50000,    -- second waypoint distance from spawn point
  DRONE_ROUTE_DISTANCE_M        = 100000,   -- distance for drone straight-line flight
  UNIT_ID_OFFSET                = 10000,
  GROUP_ID_OFFSET               = 5000,
  FORMATION_BACK_M              = 80,       -- vic spacing down-track
  FORMATION_SIDE_M              = 60,       -- vic spacing across-track
  MSG_DURATION_SEC              = 18,
  SPAWN_OPTION_RETRY_SEC        = 2,        -- delayed re-apply of AI options
  ALT_TYPE_BARO                 = "BARO",
  WP_TYPE_TURNING               = "Turning Point",
  MIN_SPEED_MS                  = 60,       -- floor on randomized speed (~115 kts)
  MAX_GROUP_SIZE                = 8,        -- build-mode aircraft cap
  DEFAULT_BUILD_COUNT           = 2,
  MIN_VELOCITY_FOR_HEADING_MS   = 2,        -- velocity fallback threshold for heading
}
FTS.Constants = C

--=============================================================================
-- UTIL
--=============================================================================
local Util = FTS.Util

function Util.deepCopy(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[Util.deepCopy(k)] = Util.deepCopy(v) end
  return c
end

-- resolve a per-entry value against the global config fallback.
-- optional ctx table takes highest priority (e.g. distance/bearing chosen from menu).
function Util.cfgVal(def, key, ctx)
  if ctx and ctx[key] ~= nil then return ctx[key] end
  if def and def[key] ~= nil then return def[key] end
  return FTS.cfg[key]
end

function Util.randRange(base, var)
  return base + (math.random() * 2 - 1) * var
end

-- DCS only accepts exact title-case skill strings in group tables; accept any
-- case from the user, warn and fall back to "High" on unknown values.
function Util.normalizeSkill(s, defName)
  local valid = {
    average = "Average", good = "Good", high = "High",
    excellent = "Excellent", ace = "Ace",
  }
  local key = type(s) == "string" and s:lower()
  if key and valid[key] then return valid[key] end
  env.info(string.format(
    "BanditSpawner: invalid skill '%s'%s -- falling back to 'High' (valid: Average, Good, High, Excellent, Ace).",
    tostring(s),
    defName and (" for spawn '" .. defName .. "'") or ""))
  return "High"
end

function Util.msg(gid, text)
  if not gid then return end
  trigger.action.outTextForGroup(gid, text, C.MSG_DURATION_SEC)
end

function Util.formatFt(m)
  local ft = math.floor(m * M2FT + 0.5)
  local s = tostring(math.abs(ft))
  local sign = ft < 0 and "-" or ""
  local parts = {}
  while #s > 3 do
    parts[#parts + 1] = s:sub(-3)
    s = s:sub(1, -4)
  end
  parts[#parts + 1] = s
  local out = parts[#parts]
  for i = #parts - 1, 1, -1 do
    out = out .. "," .. parts[i]
  end
  return sign .. out
end

-- DCS-safe wrappers for common API calls.
-- These centralize pcall/error handling.  Returns ok, ... on success
-- and nil, err on failure.  Higher-level helpers below translate to the
-- traditional 'return nil on failure' idiom for value-returning calls.
function Util.safeCall(fn, ...)
  local ok, a, b, c = pcall(fn, ...)
  if not ok then return nil, a end
  return true, a, b, c
end

function Util.safeGetUnits(group)
  local ok, val = Util.safeCall(group.getUnits, group)
  if ok then return val end
  return nil
end

function Util.safeGetPosition(unit)
  local ok, val = Util.safeCall(unit.getPosition, unit)
  if ok then return val end
  return nil
end

function Util.safeGetVelocity(unit)
  local ok, val = Util.safeCall(unit.getVelocity, unit)
  if ok then return val end
  return nil
end

function Util.safeGetController(group)
  local ok, val = Util.safeCall(group.getController, group)
  if ok then return val end
  return nil
end

function Util.safeGetTypeName(unit)
  local ok, val = Util.safeCall(unit.getTypeName, unit)
  if ok then return val end
  return nil
end

function Util.safeSetOption(ctl, id, value, label)
  local ok, err = Util.safeCall(ctl.setOption, ctl, id, value)
  if not ok then
    env.info("BanditSpawner: setOption " .. tostring(label or id) .. " failed: " .. tostring(err))
  end
  return ok
end

function Util.safeDestroyObject(obj, nameHint)
  local ok, err = Util.safeCall(obj.destroy, obj)
  if not ok then
    env.info("BanditSpawner: destroy failed for " .. tostring(nameHint or "object") .. ": " .. tostring(err))
  end
  return ok
end

-- first alive, occupied player/client unit of a group
function Util.findPlayerUnit(gname)
  if not gname then return nil end
  local g = Group.getByName(gname)
  if not g then return nil end
  local units = Util.safeGetUnits(g)
  if not units then return nil end
  for _, u in ipairs(units) do
    if u and u:isExist() and u:getPlayerName() then
      return u
    end
  end
  return nil
end

-- returns true if the named player group is allowed to receive the radio menu.
-- cfg.player_groups = nil or {} means no restriction.
function Util.isAllowedGroup(gname)
  local allowed = FTS.cfg.player_groups
  if type(allowed) ~= "table" then return true end
  if #allowed == 0 then return true end
  for _, pattern in ipairs(allowed) do
    if pattern == gname then return true end
  end
  return false
end

function Util.newGroupName()
  local name
  repeat
    FTS._state.spawnCounter = FTS._state.spawnCounter + 1
    name = string.format("%s%03d", FTS.cfg.group_prefix, FTS._state.spawnCounter)
  until Group.getByName(name) == nil
  return name
end

function Util.countActiveGroups()
  local n = 0
  local dead = {}
  for name in pairs(FTS._state.active) do
    local alive = false
    local g = Group.getByName(name)
    if g then
      local units = Util.safeGetUnits(g)
      if units then
        for _, u in ipairs(units) do
          if u and u:isExist() then alive = true break end
        end
      end
    end
    if alive then n = n + 1 else dead[#dead + 1] = name end
  end
  for _, name in ipairs(dead) do FTS._state.active[name] = nil end
  return n
end

-- compass heading (radians) from orientation, with velocity fallback
function Util.getUnitHeading(unit)
  local pos = Util.safeGetPosition(unit)
  if pos and pos.x then
    return math.atan2(pos.x.z, pos.x.x)
  end
  local v = Util.safeGetVelocity(unit)
  if v then
    local sp = math.sqrt(v.x * v.x + v.z * v.z)
    if sp > C.MIN_VELOCITY_FOR_HEADING_MS then return math.atan2(v.z, v.x) end
  end
  return 0
end

--=============================================================================
-- GEO
--=============================================================================
local Geo = FTS.Geo
local U   = Util

local terrainWarned = false
function Geo.sampleTerrainHeight(sx, sz)
  -- some sandboxes strip one terrain function but not the other -- try both
  local ok, gh = U.safeCall(land.getSurfaceHeight, { x = sx, y = sz })
  if ok and type(gh) == "number" then return gh end
  local ok2, gh2 = U.safeCall(land.getHeight, { x = sx, y = sz })
  if ok2 and type(gh2) == "number" then return gh2 end
  if not terrainWarned then
    terrainWarned = true
    env.info("BanditSpawner: terrain height functions unavailable -- min-altitude floor uses 0 (sea level); logged once.")
  end
  return 0
end

function Geo.randAltSpeed(def, sx, sz, ctx)
  local cfg = FTS.cfg
  local am  = ctx and ctx.altitude_mode          -- altitude choice from the radio menu
  local alt
  if am and am.co_altitude and ctx.player_alt_ft then
    alt = ctx.player_alt_ft * FT2M               -- match the requesting player
  else
    local base = U.cfgVal(def, "alt_ft", ctx)
    local var  = U.cfgVal(def, "alt_var_ft", ctx)
    if am and am.alt_ft then                     -- fixed block picked from the menu
      base = am.alt_ft
      var  = am.alt_var_ft or 0
    end
    alt = U.randRange(base, var) * FT2M
  end
  alt = math.max(alt, Geo.sampleTerrainHeight(sx, sz) + cfg.min_alt_agl_ft * FT2M)
  local spd = U.randRange(U.cfgVal(def, "speed_kts", ctx), U.cfgVal(def, "speed_var_kts", ctx)) * KT2MS
  return alt, math.max(C.MIN_SPEED_MS, spd)   -- never slower than ~115 kts
end

function Geo.pointFromBearing(x, z, brgRad, distM)
  return x + math.cos(brgRad) * distM, z + math.sin(brgRad) * distM
end

function Geo.buildGeo(sx, sz, inboundX, inboundZ, def, ctx)
  local alt, spd = Geo.randAltSpeed(def, sx, sz, ctx)
  local mode = ctx and ctx.bearing_mode
  local bearingLabel = mode and mode.label
  return {
    x = sx, z = sz, alt = alt, speed = spd,
    heading = math.atan2(inboundZ - sz, inboundX - sx),
    dist_nm = U.cfgVal(def, "distance_nm", ctx),
    bearing_label = bearingLabel,
  }
end

-- player-relative geometry: distance_nm from the player, heading chosen by bearing mode.
function Geo.computeSpawnGeometry(playerUnit, def, ctx)
  local pos  = playerUnit:getPosition().p          -- x = north, y = alt, z = east
  local hdg  = Util.getUnitHeading(playerUnit)
  local distNm = U.randRange(U.cfgVal(def, "distance_nm", ctx), U.cfgVal(def, "distance_var_nm", ctx) or 0)
  local dist   = distNm * NM2M
  local mode = ctx and ctx.bearing_mode
  local sx, sz, banditHeading
  if mode then
    local sign = (mode.randomize_sign and (math.random() > 0.5 and 1 or -1)) or 1
    local spawnBrg = hdg + math.rad((mode.spawn_offset_deg or 0) * sign)
    banditHeading  = hdg + math.rad((mode.heading_offset_deg or 0) * sign)
    sx, sz = Geo.pointFromBearing(pos.x, pos.z, spawnBrg, dist)
  else
    local jit  = math.rad(U.cfgVal(def, "bearing_jitter_deg", ctx))
    local brg  = hdg + U.randRange(0, jit)
    sx, sz = Geo.pointFromBearing(pos.x, pos.z, brg, dist)
    banditHeading = math.atan2(pos.z - sz, pos.x - sx)
  end
  local geo = Geo.buildGeo(sx, sz, pos.x, pos.z, def, ctx)
  geo.heading = banditHeading
  geo.dist_nm = distNm
  return geo
end

-- AO reference: a trigger-zone name, or a raw map point { x = north, z = east }
function Geo.getAOReference(def)
  if type(def.ao) == "table" then return def.ao.x, def.ao.z end
  if type(def.ao) == "string" then
    local ok, z = U.safeCall(trigger.misc.getZone, def.ao)
    if ok and z and z.point then return z.point.x, z.point.z end
    -- fallback: read trigger zones straight from the mission table
    local zones = env.mission and env.mission.triggers and env.mission.triggers.zones
    if zones then
      for _, zz in pairs(zones) do
        if type(zz) == "table" and zz.name == def.ao then
          return zz.x, zz.y          -- trigger-zone coords: x = north, y = east
        end
      end
    end
  end
  return nil
end

-- AO geometry: spawn on bearing_deg FROM the reference at distance_nm, run inbound
function Geo.computeAOGeometry(def, ctx)
  local rx, rz = Geo.getAOReference(def)
  if not rx then return nil end
  local distNm = U.randRange(U.cfgVal(def, "distance_nm", ctx), U.cfgVal(def, "distance_var_nm", ctx) or 0)
  local dist   = distNm * NM2M
  local brg  = math.rad(def.bearing_deg or 0)
           + U.randRange(0, math.rad(U.cfgVal(def, "bearing_jitter_deg", ctx)))
  local sx, sz = Geo.pointFromBearing(rx, rz, brg, dist)
  local geo = Geo.buildGeo(sx, sz, rx, rz, def, ctx)       -- inbound toward the reference
  geo.dist_nm = distNm
  geo.ao = def.ao
  geo.bearing_deg = def.bearing_deg or 0
  return geo
end

local cachedRouteTasks = nil
local cachedRouteTasksHash = nil
local function routeTasksHash()
  return table.concat({
    tostring(FTS.cfg.engage_hostile_air),
    tostring(FTS.cfg.prohibit_ab),
    tostring(FTS.cfg.no_jettison),
    tostring(FTS.cfg.loiter_at_end),
  }, "|")
end

function Geo.routeTasks()
  local hash = routeTasksHash()
  if cachedRouteTasks and cachedRouteTasksHash == hash then
    return cachedRouteTasks
  end
  local tasks = {}
  if FTS.cfg.engage_hostile_air then
    tasks[#tasks + 1] = {
      enabled = true, auto = false, id = "EngageTargets",
      params = {
        targetTypes = { [1] = "Air" },   -- fighters/helos on the hostile coalition
        priority = 0,
        value = "Air",
      },
    }
  end
  if FTS.cfg.prohibit_ab then
    -- belt & suspenders next to the controller:setOption call (PROHIBIT_AB = 16)
    tasks[#tasks + 1] = {
      enabled = true, auto = false, id = "Option",
      params = { name = 16, value = true },
    }
  end
  if FTS.cfg.no_jettison then
    local j = AI and AI.Option and AI.Option.Air and AI.Option.Air.id
        and AI.Option.Air.id.PROHIBIT_JETT
    if j then
      tasks[#tasks + 1] = {
        enabled = true, auto = false, id = "Option",
        params = { name = j, value = true },   -- keep the loadout: no jettisoning
      }
    end
  end
  cachedRouteTasks = tasks
  cachedRouteTasksHash = hash
  return tasks
end

function Geo.buildRoute(geo)
  local ahead = C.ROUTE_END_DISTANCE_M
  local function wp(x, z, tasks)
    return {
      x = x, y = z, alt = geo.alt, alt_type = C.ALT_TYPE_BARO,
      speed = geo.speed, speed_locked = true,
      type = C.WP_TYPE_TURNING, action = C.WP_TYPE_TURNING,
      ETA = 0, ETA_locked = false,
      task = { id = "ComboTask", params = { tasks = tasks or {} } },
    }
  end

  -- Handle behavior modes
  local behavior = geo.behavior or FTS.cfg.behavior or "Intercept"
  
  if behavior == "Drone" then
    local droneAhead = C.DRONE_ROUTE_DISTANCE_M
    local endX = geo.x + math.cos(geo.heading) * droneAhead
    local endZ = geo.z + math.sin(geo.heading) * droneAhead

    -- Drones never engage: no Engage task, explicit ROE WEAPON HOLD on the
    -- route so targets of opportunity (like the calling player) are ignored
    -- even if the post-spawn option fails to apply.
    local droneTasks = {}
    local ROE_ID  = AI and AI.Option and AI.Option.Air and AI.Option.Air.id and AI.Option.Air.id.ROE
    local ROE_VALS = AI and AI.Option and AI.Option.Air and AI.Option.Air.val and AI.Option.Air.val.ROE
    if ROE_ID and ROE_VALS and ROE_VALS.WEAPON_HOLD then
      droneTasks[1] = {
        enabled = true, auto = false, id = "Option",
        params = { name = ROE_ID, value = ROE_VALS.WEAPON_HOLD },
      }
    end
    return {
      points = {
        wp(geo.x, geo.z, droneTasks),
        wp(endX, endZ, {}),
      },
    }
  end

  -- Standard Intercept/CAP behavior
  local endX = geo.x + math.cos(geo.heading) * ahead
  local endZ = geo.z + math.sin(geo.heading) * ahead
  local orbitTasks
  if FTS.cfg.loiter_at_end then
    orbitTasks = { {
      enabled = true, auto = false, id = "Orbit",
      params = { altitude = geo.alt, speed = geo.speed, pattern = "Race-Track", speedEdited = true },
    } }
  end

  local routeTasks = Geo.routeTasks()
  local startTasks = {}
  for i = 1, #routeTasks do startTasks[i] = routeTasks[i] end
  if geo.attack_on_spawn and geo.attack_target_group_id then
    startTasks[#startTasks + 1] = {
      enabled = true, auto = false, id = "AttackGroup",
      params = { groupId = geo.attack_target_group_id },
    }
  end

  return {
    points = {
      wp(geo.x, geo.z, startTasks),
      wp(endX, endZ, orbitTasks),
    },
  }
end

--=============================================================================
-- PAYLOAD
--=============================================================================
local Payload = FTS.Payload

function Payload.topOffGun(payload)
  if FTS.cfg.guns_full then payload.gun = 100 end
end

function Payload.applyCleanPayload(unitTbl)
  local old = unitTbl.payload or {}
  unitTbl.payload = {
    pylons        = {},                                   -- no stores => no bombs/missiles
    gun           = old.gun or 100,
    internal_fuel = old.internal_fuel,                    -- keep whatever was set (nil = module default)
    chaff         = old.chaff,
    flare         = old.flare,
  }
  Payload.topOffGun(unitTbl.payload)
end

-- allowTypeOverride (build mode): DCS renames unit type strings between builds
-- (e.g. "F-16C_50" became "F-16C bl.50"); if the donor group is single-type but
-- that type differs from def.airframe, adopt the donor's type outright.
function Payload.applyDonorPayload(unitTbl, def, allowTypeOverride)
  local dname = U.cfgVal(def, "payload_from")
  if type(dname) == "table" then dname = dname[unitTbl.type] end
  if type(dname) ~= "string" or dname == "" then return false end

  local donor = FTS.Template.findTemplateGroup(dname)
  if not donor or not donor.units or not donor.units[1] then
    env.info("BanditSpawner: payload donor group '" .. tostring(dname) .. "' not found in the mission.")
    return false
  end
  local du
  for _, u in ipairs(donor.units) do
    if u.type == unitTbl.type then du = u break end
  end
  if not du and allowTypeOverride then
    local only
    for i, u in ipairs(donor.units) do
      if i == 1 then only = u.type
      elseif u.type ~= only then only = nil break end
    end
    if only ~= nil then
      du = donor.units[1]
      if only ~= unitTbl.type then
        env.info("BanditSpawner: donor '" .. dname .. "' has '" .. tostring(only) ..
                 "' units, not '" .. tostring(unitTbl.type) .. "' -- adopting the donor's type (rename the entry's airframe to match).")
        unitTbl.type = du.type
      end
    end
  end
  if not du then
    local have = {}
    for _, u in ipairs(donor.units) do have[#have + 1] = tostring(u.type) end
    env.info("BanditSpawner: payload donor group '" .. tostring(dname) .. "' contains no " ..
             tostring(unitTbl.type) .. " unit (found: " .. table.concat(have, ", ") .. ").")
    return false
  end
  unitTbl.payload = U.deepCopy(du.payload or {})
  Payload.topOffGun(unitTbl.payload)
  -- some loadouts hang off aircraft properties (CFTs, fuselage stores, etc.)
  if du.AddPropAircraft then unitTbl.AddPropAircraft = U.deepCopy(du.AddPropAircraft) end
  if du.AddPropHelicopter then unitTbl.AddPropHelicopter = U.deepCopy(du.AddPropHelicopter) end
  return true
end

-- build-mode payload resolution: donor payload if configured, else clean
function Payload.resolveBuildPayload(unitTbl, def)
  if def and def.payload_from then
    if Payload.applyDonorPayload(unitTbl, def, true) then return end
    env.info("BanditSpawner: payload_from failed for '" .. tostring(def.label) .. "', spawning clean.")
  end
  Payload.applyCleanPayload(unitTbl)
end

-- clone-mode payload strategies: donor (with template fallback), clean, or keep ME payload
function Payload.applyTemplatePayload(unitTbl)
  unitTbl.payload = unitTbl.payload or {}
  Payload.topOffGun(unitTbl.payload)
end

function Payload.applyDonorOrTemplatePayload(unitTbl, def)
  if Payload.applyDonorPayload(unitTbl, def) then return end
  Payload.applyTemplatePayload(unitTbl)          -- donor missing/mismatched: keep template payload
end

local cloneStrategies = {
  donor    = Payload.applyDonorOrTemplatePayload,
  clean    = Payload.applyCleanPayload,
  template = Payload.applyTemplatePayload,
}

function Payload.resolveCloneStrategy(def)
  if def and def.payload_from then return "donor" end
  if FTS.cfg.override_clone_payload then return "clean" end
  return "template"
end

--=============================================================================
-- TEMPLATE
--=============================================================================
local Template    = FTS.Template
local GroupBuilder = FTS.GroupBuilder

-- template (clone mode): pull group data from the static mission table.
-- Works for late-activation groups regardless of activation state.
function Template.findTemplateGroup(name)
  local coal = env.mission and env.mission.coalition
  if not coal then return nil end
  for _, coa in pairs(coal) do
    local countries = coa.country
    if countries then
      for _, ctry in pairs(countries) do
        for _, catKey in pairs({ "plane", "helicopter" }) do
          local cat = ctry[catKey]
          if cat and cat.group then
            for _, g in pairs(cat.group) do
              if type(g) == "table" and g.name == name then
                return U.deepCopy(g)
              end
            end
          end
        end
      end
    end
  end
  return nil
end

-- re-anchor a copied template group at the spawn point, rotated to the bandit heading
function Template.buildFromTemplate(tpl, geo, gname, def)
  tpl = U.deepCopy(tpl)               -- never mutate the env.mission template table
  local gidNum = tonumber(gname:match("%d+$")) or 0
  local units = tpl.units
  if not units or not units[1] or not units[1].type then return nil end

  -- mission-file unit heading conventions: heading = compass radians, psi = -heading
  local leadOld = units[1].heading or (-(units[1].psi or 0))
  local delta   = geo.heading - leadOld
  local s, c    = math.sin(delta), math.cos(delta)
  local ox, oy  = units[1].x, units[1].y

  local newUnits = {}
  for i, u in ipairs(units) do
    local nu = U.deepCopy(u)
    -- offset from lead, rotated into the new heading frame
    local rx, ry = u.x - ox, u.y - oy
    nu.x = geo.x + rx * c - ry * s
    nu.y = geo.z + rx * s + ry * c
    local hOld = u.heading or (-(u.psi or leadOld))
    local hNew = hOld + delta
    nu.heading = hNew
    nu.psi     = -hNew
    nu.alt     = geo.alt
    nu.alt_type = C.ALT_TYPE_BARO
    nu.speed   = geo.speed
    nu.parking    = nil               -- strip any ground-tie the template carried
    nu.parking_id = nil
    nu.name    = gname .. "-" .. i
    nu.unitId   = C.UNIT_ID_OFFSET + gidNum * 10 + i  -- template unitIds repeat across clones
    -- clones keep the skill set on the template in the ME (always valid)
    -- apply clone payload strategy (donor, clean, or keep ME payload with full gun)
    local strategy = cloneStrategies[Payload.resolveCloneStrategy(def)]
    strategy(nu, def)
    newUnits[i] = nu
  end

  return GroupBuilder.new(tpl, gname, def, geo)
    :withUnits(newUnits)
    :withCloneOverrides()
    :build()
end

--=============================================================================
-- GROUP BUILDER
--=============================================================================
local GroupBuilder = FTS.GroupBuilder

-- Fluent builder used by BOTH clone-mode and build-mode spawns so every spawned
-- group table receives the same base configuration (name, route, task, groupId, etc).
-- Controller-level options (afterburner, jettison, ROE, RTB) are applied later by
-- the shared Spawn.applySpawnOptions() function; waypoint-level option tasks are
-- injected by the shared Geo.routeTasks() function used by Geo.buildRoute().
function GroupBuilder.new(base, gname, def, geo)
  local gidNum = tonumber(gname:match("%d+$")) or 0
  local builder = {
    gdata = U.deepCopy(base or {}),
    def   = def,
    geo   = geo,
  }
  setmetatable(builder, { __index = GroupBuilder })
  return builder
    :withName(gname)
    :withGroupId(gidNum)
    :withRoute()
    :withTask()
    :withDefaults()
end

function GroupBuilder:withName(name)
  self.gdata.name = name
  return self
end

function GroupBuilder:withTask(task)
  -- "Intercept", "CAP", "Escort", etc.  Same objective for every spawn path.
  self.gdata.task = task or U.cfgVal(self.def, "task")
  -- Drones have no combat role; keeps the AI from behaving as a fighter.
  if U.cfgVal(self.def, "behavior") == "Drone" and not (self.def and self.def.task) then
    self.gdata.task = "Nothing"
  end
  return self
end

function GroupBuilder:withRoute()
  -- Route already includes shared en-route tasks: Engage Air, PROHIBIT_AB,
  -- PROHIBIT_JETT (see Geo.routeTasks).
  self.gdata.route = Geo.buildRoute(self.geo)
  return self
end

function GroupBuilder:withUnits(units)
  self.gdata.units = units
  return self
end

function GroupBuilder:withGroupId(gidNum)
  self.gdata.groupId = C.GROUP_ID_OFFSET + (gidNum or 0)
  return self
end

function GroupBuilder:withDefaults()
  self.gdata.hidden = false
  return self
end

function GroupBuilder:withFreshDefaults()
  -- fields needed by a newly-built group (not present in a cloned template)
  self.gdata.communication  = true
  self.gdata.frequency     = 124
  self.gdata.modulation    = 0
  self.gdata.radioSet      = false
  self.gdata.uncontrollable = false
  self.gdata.tasks         = {}
  return self
end

function GroupBuilder:withCloneOverrides()
  -- a cloned late-activation template must be forced alive and controllable
  self.gdata.lateActivation = false
  self.gdata.uncontrolled  = false
  self.gdata.start_time    = 0
  return self
end

function GroupBuilder:build()
  return self.gdata
end
--=============================================================================
-- SPAWN
--=============================================================================
local Spawn = FTS.Spawn

-- pick a country on the coalition OPPOSITE the clicking group's coalition,
-- using the mission's own country list (with CJTF fallbacks that always exist).
function Spawn.autoCountryFor(gname)
  local enemyKey = "red"
  local g = Group.getByName(gname)
  local ok, side = g and U.safeCall(g.getCoalition, g)
  if ok and side == coalition.side.RED then enemyKey = "blue" end
  local coa = env.mission and env.mission.coalition and env.mission.coalition[enemyKey]
  if coa and coa.country then
    for _, ctry in pairs(coa.country) do
      if type(ctry) == "table" and type(ctry.id) == "number" then return ctry.id end
    end
  end
  if enemyKey == "red" then
    return country.id.CJTF_RED or country.id.RUSSIA
  end
  return country.id.CJTF_BLUE or country.id.USA
end

-- fresh group of a chosen airframe
function Spawn.buildFreshGroup(def, geo, gname)
  local count = math.max(1, math.min(def.count or C.DEFAULT_BUILD_COUNT, C.MAX_GROUP_SIZE))
  local c, s  = math.cos(geo.heading), math.sin(geo.heading)
  local gidNum = tonumber(gname:match("%d+$")) or 0
  local units = {}
  for i = 1, count do
    -- vic-ish formation offsets in the track/right frame (meters)
    local back, side = 0, 0
    if i > 1 then
      local k = math.floor(i / 2)          -- 2->1, 3->1, 4->2, 5->2 ...
      back = -C.FORMATION_BACK_M * k
      side = ((i % 2 == 0) and -1 or 1) * C.FORMATION_SIDE_M * k
    end
    local px = geo.x + back * c + side * (-s)   -- right vector = (-sin h, cos h)
    local pz = geo.z + back * s + side * c
    local u = {
      name        = gname .. "-" .. i,
      type        = def.airframe,
      skill       = U.normalizeSkill(U.cfgVal(def, "skill"), def.label),
      x = px, y = pz,
      alt = geo.alt, alt_type = C.ALT_TYPE_BARO,
      heading = geo.heading, psi = -geo.heading,
      speed = geo.speed,
      onboard_num = string.format("%03d", i),
      callsign    = { [1] = 1, [2] = 1, [3] = i, name = "Enfield1" .. i },
      unitId      = C.UNIT_ID_OFFSET + gidNum * 10 + i,
    }
    Payload.resolveBuildPayload(u, def)
    units[i] = u
  end
  return GroupBuilder.new({}, gname, def, geo)
    :withUnits(units)
    :withFreshDefaults()
    :build(), units[1] and units[1].type   -- type may have been corrected to the donor's
end

function Spawn.applySpawnOptions(gname, def, behaviorOverride)
  local g = Group.getByName(gname)
  if not g then return end
  local ctl = U.safeGetController(g)
  if not ctl then
    env.info("BanditSpawner: no AI controller for " .. tostring(gname) .. " -- options NOT applied")
    return
  end
  if FTS.cfg.prohibit_ab then
    U.safeSetOption(ctl, AI.Option.Air.id.PROHIBIT_AB, true, "PROHIBIT_AB")
  end
  if FTS.cfg.no_jettison then
    local j = AI.Option.Air.id.PROHIBIT_JETT
    if j then
      U.safeSetOption(ctl, j, true, "PROHIBIT_JETT")
    else
      env.info("BanditSpawner: PROHIBIT_JETT enum missing in this DCS build; waypoint Option task may still cover it.")
    end
  end
  if FTS.cfg.allow_rtb == false then
    for _, key in ipairs({ "RTB_ON_BINGO", "RTB_ON_OUT_OF_AMMO" }) do
      local id = AI.Option.Air.id[key]
      if id then
        U.safeSetOption(ctl, id, false, key)
      end
    end
  end
  -- ROE: config default for combat bandits; drones are always WEAPON HOLD
  -- so they fly straight and never turn onto targets of opportunity.
  local roeVal = ROEMap[FTS.cfg.default_roe] or AI.Option.Air.val.ROE.WEAPON_FREE
  local behavior = behaviorOverride or U.cfgVal(def, "behavior")
  if behavior == "Drone" then
    roeVal = AI.Option.Air.val.ROE.WEAPON_HOLD
  end
  U.safeSetOption(ctl, AI.Option.Air.id.ROE, roeVal, "ROE")
end

-- Re-task an already-airborne bandit group with a route rebuilt for a new
-- behavior, then re-apply spawn options (drones end up weapons-hold).
-- "Intercept" steers the group toward targetGroup (usually the requesting
-- flight) when that flight is still alive. Returns ok, errMsg.
function Spawn.retaskBehavior(gname, def, behavior, targetGroup)
  local okG, g = pcall(Group.getByName, gname)
  if not okG or not g then return false, "group gone" end
  local ctl = U.safeGetController(g)
  if not ctl then return false, "no AI controller" end
  local okU, unit = pcall(function()
    local us = g:getUnits()
    return us and us[1]
  end)
  if not okU or not unit then return false, "no live unit" end
  local okP, pos = pcall(unit.getPosition, unit)
  if not okP or type(pos) ~= "table" or type(pos.p) ~= "table" then return false, "no position" end

  -- Keep the current heading & airspeed so the re-task doesn't make the jet wallow.
  local speed   = (U.cfgVal(def, "speed_kts") or 450) * KT2MS
  local heading = 0
  local okV, vel = pcall(unit.getVelocity, unit)
  if okV and type(vel) == "table" then
    local sp = math.sqrt((vel.x or 0)^2 + (vel.z or 0)^2)
    if sp > 5 then
      speed, heading = sp, math.atan2(vel.z, vel.x)
    end
  end

  local geo = {
    x = pos.p.x, z = pos.p.z, alt = pos.p.y,
    heading = heading, speed = speed, behavior = behavior,
  }

  if behavior ~= "Drone" then
    if targetGroup then
      local okT, tx, tz = pcall(function()
        local us = targetGroup:getUnits()
        local p  = us and us[1] and us[1]:getPosition()
        if type(p) == "table" and type(p.p) == "table" then
          return p.p.x, p.p.z
        end
        return nil, nil
      end)
      if okT and tx then
        geo.heading = math.atan2(tz - geo.z, tx - geo.x)
        if U.cfgVal(def, "attack_on_spawn") then
          local okId, tid = pcall(targetGroup.getID, targetGroup)
          if okId and tid then
            geo.attack_on_spawn        = true
            geo.attack_target_group_id = tid
          end
        end
      end
    end
  end

  -- A "Mission" task wholesale-replaces the group's current route & tasks.
  local route   = Geo.buildRoute(geo)
  local mission = { id = "Mission", params = { airborne = true, route = route } }
  local okS, errS = pcall(function() ctl:setTask(mission) end)
  if not okS then return false, "setTask failed: " .. tostring(errS) end

  Spawn.applySpawnOptions(gname, def, behavior)
  return true
end

-- Radio callbacks receive ONE table argument (the 'anyArg' from
-- addCommandForGroup). Unpack it here.

local function validateSpawnArgs(arg)
  if type(arg) ~= "table" then
    env.info("BanditSpawner: malformed menu callback; spawn aborted.")
    return nil
  end
  local def, gid, gname = arg.def, arg.gid, arg.gname
  if not def or gid == nil or not gname then
    env.info("BanditSpawner: malformed menu callback arguments; spawn aborted.")
    return nil
  end
  return { def = def, gid = gid, gname = gname, distance_nm = arg.distance_nm, distance_var_nm = arg.distance_var_nm, distance_label = arg.distance_label, bearing_mode = arg.bearing_mode, altitude_mode = arg.altitude_mode }
end

local function isOnCooldown(gid)
  local now = timer.getTime()
  if now - (FTS._state.lastSpawn[gid] or -1e6) < FTS.cfg.cooldown_sec then
    U.msg(gid, "Bandit spawner rearming, try again in a few seconds.")
    return true
  end
  return false
end

local function atActiveLimit(gid)
  if FTS.cfg.max_active > 0 and U.countActiveGroups() >= FTS.cfg.max_active then
    U.msg(gid, string.format("Bandit limit reached (%d active). Shoot some down first!", FTS.cfg.max_active))
    return true
  end
  return false
end

local function resolveGeometry(gnamePlayer, def, gid, ctx)
  local playerUnit = U.findPlayerUnit(gnamePlayer)
  if ctx and playerUnit then
    -- remember the requesting player's altitude so a co-altitude menu pick can match it
    local ppos = U.safeGetPosition(playerUnit)
    if ppos and ppos.p then ctx.player_alt_ft = ppos.p.y * M2FT end
  end
  local geo
  if def.ao then
    geo = Geo.computeAOGeometry(def, ctx)
    if not geo then
      U.msg(gid, "Bandit spawner: AO reference '" .. tostring(def.ao) .. "' not found." .. "\nAdd a trigger zone with that name in the ME, or set ao = { x = ..., z = ... }.")
      return nil
    end
    geo.behavior = U.cfgVal(def, "behavior")
  elseif playerUnit then
    geo = Geo.computeSpawnGeometry(playerUnit, def, ctx)
    geo.behavior = U.cfgVal(def, "behavior")
    geo.attack_on_spawn = U.cfgVal(def, "attack_on_spawn")
    local ok, pg = U.safeCall(playerUnit.getGroup, playerUnit)
    if ok and pg then
      geo.attack_target_group_id = pg:getID()
      geo.attack_target_name   = U.safeGetTypeName(playerUnit) or pg:getName()
      geo.attack_target_unit   = playerUnit:getName()
    end
  else
    U.msg(gid, "Bandit spawner: no alive player aircraft found in your group.")
    return nil
  end
  return geo
end

local function buildGroupData(def, geo, gname, gid)
  local gdata, what, wantType
  if def.mode == "clone" then
    local tpl = Template.findTemplateGroup(def.template)
    if not tpl then
      U.msg(gid, "Bandit spawner: template group '" .. tostring(def.template) ..
              "' not found in the mission file (check the late-activation group name).")
      return nil
    end
    gdata = Template.buildFromTemplate(tpl, geo, gname, def)
    if not gdata then
      U.msg(gid, "Bandit spawner: template group '" .. tostring(def.template) .. "' has no aircraft.")
      return nil
    end
    what = tostring(#gdata.units) .. "x " .. tostring(gdata.units[1].type)
  else
    gdata, wantType = Spawn.buildFreshGroup(def, geo, gname)
    what  = tostring(#gdata.units) .. "x " .. tostring(wantType or def.airframe)
  end
  return gdata, what, wantType
end

local function resolveCountry(gnamePlayer)
  local countryId = FTS.cfg.country
  if type(countryId) ~= "number" then
    countryId = Spawn.autoCountryFor(gnamePlayer)
  end
  return countryId
end

local function spawnGroup(gdata, countryId, gid)
  local ok, err = U.safeCall(function()
    coalition.addGroup(countryId, Group.Category.AIRPLANE, gdata)
  end)
  if not ok then
    U.msg(gid, "Bandit spawner: spawn failed (" .. tostring(err) .. ")")
    return false
  end
  return true
end

local function buildContext(args)
  local ctx = {}
  if args.distance_nm ~= nil then ctx.distance_nm = args.distance_nm end
  if args.distance_var_nm ~= nil then ctx.distance_var_nm = args.distance_var_nm end
  if args.distance_label ~= nil then ctx.distance_label = args.distance_label end
  if args.bearing_mode ~= nil then ctx.bearing_mode = args.bearing_mode end
  if args.altitude_mode ~= nil then ctx.altitude_mode = args.altitude_mode end
  return next(ctx) and ctx
end

local function formatContextLabel(ctx)
  if not ctx then return "" end
  local parts = {}
  if ctx.distance_nm then parts[#parts + 1] = ctx.distance_label or (ctx.distance_nm .. " nm") end
  if ctx.bearing_mode then parts[#parts + 1] = ctx.bearing_mode.label end
  if ctx.altitude_mode then parts[#parts + 1] = ctx.altitude_mode.label end
  return " (" .. table.concat(parts, ", ") .. ")"
end
local function finalizeSpawn(gname, gid, def, geo, what, wantType, ctx)
  local cfg = FTS.cfg
  local now = timer.getTime()
  FTS._state.active[gname]   = { def = def }
  FTS._state.lastSpawn[gid]  = now
  Spawn.applySpawnOptions(gname, def)
  -- DCS sometimes drops options set in the same tick a group is born -> re-apply
  timer.scheduleFunction(function(gn) U.safeCall(Spawn.applySpawnOptions, gn, def) end, gname, timer.getTime() + C.SPAWN_OPTION_RETRY_SEC)

  -- sanity check: a wrong airframe string makes DCS silently substitute some
  -- other aircraft type -- detect it and complain on-screen + in dcs.log.
  if def.mode == "build" then
    local g = Group.getByName(gname)
    local units = g and U.safeGetUnits(g)
    local u = units and units[1]
    local tn = u and U.safeGetTypeName(u)
    if tn and tn ~= (wantType or def.airframe) then
      local e = "BanditSpawner: airframe '" .. tostring(wantType or def.airframe) .. "' is not a real DCS unit type -- DCS spawned '" .. tostring(tn) .. "' instead."
      env.info(e)
      U.msg(gid, e .. "\nFix the entry's 'airframe' to the exact ME type string (unit.type in the mission file).")
    end
  end

  local where
  if def.ao then
    where = string.format("%0.1f NM from '%s' on bearing %03d, running inbound.",
                          geo.dist_nm, tostring(def.ao), geo.bearing_deg)
  else
    where = string.format("%0.1f NM, %s%s",
                          geo.dist_nm, geo.bearing_label or "nose on", formatContextLabel(ctx))
  end
  U.msg(gid, string.format(
    "Bandits inbound!\n%s\n%s\n%s ft, %d kt. Afterburner: %s",
    what, where,
    U.formatFt(geo.alt),
    math.floor(geo.speed * MS2KT + 0.5),
    cfg.prohibit_ab and "PROHIBITED" or "free"
  ))
end

function Spawn.doSpawn(arg)
  local args = validateSpawnArgs(arg)
  if not args then return end
  local def, gid, gnamePlayer = args.def, args.gid, args.gname

  if isOnCooldown(gid) then return end
  if atActiveLimit(gid) then return end

  local ctx = buildContext(args)
  local geo = resolveGeometry(gnamePlayer, def, gid, ctx)
  if not geo then return end

  local gname = U.newGroupName()
  local gdata, what, wantType = buildGroupData(def, geo, gname, gid)
  if not gdata then return end

  local countryId = resolveCountry(gnamePlayer)
  if not spawnGroup(gdata, countryId, gid) then return end

  finalizeSpawn(gname, gid, def, geo, what, wantType, ctx)
end

--=============================================================================
-- MENU
--=============================================================================
local Menu = FTS.Menu

-- "remove all bandits" housekeeping (MP admins love this)
function Menu.onDespawn(arg)
  local gid = arg and arg.gid
  local n = 0
  for name in pairs(FTS._state.active) do
    local g = Group.getByName(name)
    if g then
      if not U.safeDestroyObject(g, name) then
        local units = U.safeGetUnits(g)
        if units then
          for _, u in ipairs(units) do
            U.safeDestroyObject(u, name .. "-unit")
          end
        end
      end
      n = n + 1
    end
    FTS._state.active[name] = nil
  end
  U.msg(gid, string.format("Bandit spawner: removed %d spawned group(s).", n))
end

function Menu.addMenusForGroup(gid, gname)
  if FTS._state.hasMenu[gid] then return end
  local ok, path = U.safeCall(missionCommands.addSubMenuForGroup, gid, FTS.cfg.menu_name)
  if not ok or not path then return end

  local distances = FTS.cfg.spawn_distances_nm
  local modes     = FTS.cfg.bearing_modes
  local nested    = type(distances) == "table" and #distances > 0
                and type(modes)     == "table" and #modes > 0

  -- DCS radio pages have 10 usable slots (F1-F10; F11/F12 are the paging
  -- rows), so a flat 12-item page leaves the last items unreachable.
  -- Split defs into two tiers; AO defs get their own page.
  local bandits, aos = {}, {}
  for _, def in ipairs(FTS.cfg.spawns) do
    if type(def) == "table" and def.ao then aos[#aos + 1] = def else bandits[#bandits + 1] = def end
  end

  local function addTier(label, defs)
    if #defs == 0 then return end
    local tierPath = path
    -- only add the extra submenu level when there is actually something to split
    if #bandits > 0 and #aos > 0 then
      local okT, p = U.safeCall(missionCommands.addSubMenuForGroup, gid, label, path)
      if not okT or not p then
        env.info("BanditSpawner: failed to add '" .. label .. "' submenu")
        return
      end
      tierPath = p
    end
    if nested then Menu.addNestedMenus(gid, gname, tierPath, defs)
    else Menu.addSpawnCommands(gid, gname, tierPath, nil, defs) end
  end

  addTier("Bandits", bandits)
  addTier("AO Spawns", aos)

  -- Control/admin tier: ROE, behavior, and despawn live here so they can never
  -- overflow the root page's usable slots.
  local ok3, controlPath = U.safeCall(missionCommands.addSubMenuForGroup, gid, FTS.cfg.menu_name .. " Control", path)
  if ok3 and controlPath then
    Menu.addControlMenu(gid, gname, controlPath)
    if FTS.cfg.allow_despawn then
      local ok2 = U.safeCall(missionCommands.addCommandForGroup, gid, FTS.cfg.despawn_label, controlPath, Menu.onDespawn, { gid = gid })
      if not ok2 then
        env.info("BanditSpawner: failed to add despawn command")
      end
    end
  end

  FTS._state.hasMenu[gid] = true
end

-- build the table passed to Spawn.doSpawn by every menu command.
local function buildSpawnArg(def, gid, gname, ctx, altitude_mode)
  return {
    def = def, gid = gid, gname = gname,
    distance_nm = ctx and ctx.distance_nm,
    distance_var_nm = ctx and ctx.distance_var_nm,
    distance_label  = ctx and ctx.distance_label,
    bearing_mode = ctx and ctx.bearing_mode,
    altitude_mode = altitude_mode,
  }
end

function Menu.addSpawnCommand(gid, gname, parentPath, def, ctx)
  local ok = U.safeCall(missionCommands.addCommandForGroup, gid, def.label, parentPath, Spawn.doSpawn, buildSpawnArg(def, gid, gname, ctx))
  if not ok then
    env.info("BanditSpawner: failed to add spawn command '" .. tostring(def.label) .. "'")
  end
end

function Menu.hasAltitudeModes()
  local am = FTS.cfg.altitude_modes
  return type(am) == "table" and #am > 0
end

function Menu.addAltitudeCommands(gid, gname, parentPath, def, ctx)
  for _, am in ipairs(FTS.cfg.altitude_modes) do
    local ok = U.safeCall(missionCommands.addCommandForGroup, gid, am.label, parentPath, Spawn.doSpawn, buildSpawnArg(def, gid, gname, ctx, am))
    if not ok then
      env.info("BanditSpawner: failed to add altitude command '" .. tostring(am.label) .. "'")
    end
  end
end

function Menu.addSpawnCommands(gid, gname, parentPath, ctx, defs)
  for _, def in ipairs(defs or FTS.cfg.spawns) do
    if Menu.hasAltitudeModes() then
      local ok, subPath = U.safeCall(missionCommands.addSubMenuForGroup, gid, def.label, parentPath)
      if ok and subPath then
        Menu.addAltitudeCommands(gid, gname, subPath, def, ctx)
      else
        env.info("BanditSpawner: failed to add bandit type submenu '" .. tostring(def.label) .. "'")
      end
    else
      Menu.addSpawnCommand(gid, gname, parentPath, def, ctx)
    end
  end
end

-- New Dynamic Control Menu
function Menu.addControlMenu(gid, gname, path)
  local function setROE(roeName)
    return function(arg)
      local targetGid = arg.gid
      -- For simplicity, apply to ALL active spawned bandits
      for name in pairs(FTS._state.active) do
        local g = Group.getByName(name)
        if g then
          local ctl = U.safeGetController(g)
          if ctl then
            U.safeSetOption(ctl, AI.Option.Air.id.ROE, ROEMap[roeName], "ROE")
          end
        end
      end
      U.msg(targetGid, "All spawned bandits set to " .. roeName)
    end
  end

  local function setBehavior(behaviorName)
    return function(arg)
      local targetGid = arg.gid
      -- Re-task all live spawned bandits. "Intercept" steers them at the
      -- requesting flight when it is still around; "Drone" turns them into
      -- straight-and-level, weapons-hold traffic.
      local okT, targetGroup = pcall(Group.getByName, arg.groupName)
      if not okT then targetGroup = nil end
      local changed, failed = 0, 0
      for name, rec in pairs(FTS._state.active) do
        local ok, err = Spawn.retaskBehavior(name, type(rec) == "table" and rec.def or nil, behaviorName, targetGroup)
        if ok then
          changed = changed + 1
        elseif err == "group gone" then
          FTS._state.active[name] = nil
        else
          failed = failed + 1
          env.info("BanditSpawner: behavior change failed for " .. tostring(name) .. ": " .. tostring(err))
        end
      end
      if changed == 0 and failed == 0 then
        U.msg(targetGid, "Bandit spawner: no active spawned bandits to re-task.")
      else
        U.msg(targetGid, string.format("Bandit spawner: %d group(s) re-tasked to %s.", changed, behaviorName)
          .. (failed > 0 and string.format(" (%d failed, see log)", failed) or ""))
      end
    end
  end

  -- ROE Submenu
  local okROE, roePath = U.safeCall(missionCommands.addSubMenuForGroup, gid, "Set ROE", path)
  if okROE and roePath then
    for _, roe in ipairs(FTS.cfg.roe_options) do
      U.safeCall(missionCommands.addCommandForGroup, gid, roe, roePath, setROE(roe), { gid = gid })
    end
  end

  -- Behavior Submenu
  local okBeh, behPath = U.safeCall(missionCommands.addSubMenuForGroup, gid, "Set Behavior", path)
  if okBeh and behPath then
    for _, beh in ipairs(FTS.cfg.behavior_options) do
      U.safeCall(missionCommands.addCommandForGroup, gid, beh, behPath, setBehavior(beh), { gid = gid, groupName = gname })
    end
  end
end

function Menu.addDistanceBearingSubMenus(gid, gname, parentPath, def)
  local distances = FTS.cfg.spawn_distances_nm
  local modes     = FTS.cfg.bearing_modes
  local withAlt   = Menu.hasAltitudeModes()
  for _, dopt in ipairs(distances) do
    local dnm, dvar, distLabel
    if type(dopt) == "table" then
      dnm, dvar = dopt.dist_nm, dopt.dist_var_nm
      distLabel = dopt.label or (tostring(dnm) .. " nm")
    else
      dnm, distLabel = dopt, tostring(dopt) .. " nm"
    end
    local ok1, distPath = U.safeCall(missionCommands.addSubMenuForGroup, gid, distLabel, parentPath)
    if not ok1 or not distPath then
      env.info("BanditSpawner: failed to add distance submenu '" .. distLabel .. "'")
    else
      for _, mode in ipairs(modes) do
        if withAlt then
          -- bearing mode becomes a submenu holding the altitude choices
          local ok2, modePath = U.safeCall(missionCommands.addSubMenuForGroup, gid, mode.label, distPath)
          if ok2 and modePath then
            Menu.addAltitudeCommands(gid, gname, modePath, def, { distance_nm = dnm, distance_var_nm = dvar, distance_label = distLabel, bearing_mode = mode })
          else
            env.info("BanditSpawner: failed to add bearing submenu '" .. mode.label .. "'")
          end
        else
          local ok2 = U.safeCall(missionCommands.addCommandForGroup, gid, mode.label, distPath, Spawn.doSpawn, buildSpawnArg(def, gid, gname, { distance_nm = dnm, distance_var_nm = dvar, distance_label = distLabel, bearing_mode = mode }))
          if not ok2 then
            env.info("BanditSpawner: failed to add bearing command '" .. mode.label .. "'")
          end
        end
      end
    end
  end
end

function Menu.addNestedMenus(gid, gname, path, defs)
  for _, def in ipairs(defs or FTS.cfg.spawns) do
    local ok1, entryPath = U.safeCall(missionCommands.addSubMenuForGroup, gid, def.label, path)
    if not ok1 or not entryPath then
      env.info("BanditSpawner: failed to add bandit type submenu '" .. tostring(def.label) .. "'")
    else
      Menu.addDistanceBearingSubMenus(gid, gname, entryPath, def)
    end
  end
end

function Menu.scanPlayers()
  for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED, coalition.side.NEUTRAL }) do
    local ok, players = U.safeCall(coalition.getPlayers, side)
    if ok and players then
      for _, u in pairs(players) do
        if u and u:isExist() then
          local g = u:getGroup()
          if g and U.isAllowedGroup(g:getName()) then Menu.addMenusForGroup(g:getID(), g:getName()) end
        end
      end
    end
  end
end
-- late-spawning clients get their menu on BIRTH
function Menu.onBirthEvent(_, event)
  if event.id ~= world.event.S_EVENT_BIRTH then return end
  local u = event.initiator
  if u and u:isExist() and u.getPlayerName and u:getPlayerName() then
    local g = u:getGroup()
    if g and U.isAllowedGroup(g:getName()) then Menu.addMenusForGroup(g:getID(), g:getName()) end
  end
end

world.addEventHandler({ onEvent = Menu.onBirthEvent })  -- handler table uses the named function

--=============================================================================
-- LOAD-TIME VALIDATION
--=============================================================================
local function validateSpawnDefs()
  local spawns = FTS.cfg.spawns
  if type(spawns) ~= "table" then
    env.info("BanditSpawner: cfg.spawns is missing or not a table; no spawn entries defined.")
    return
  end
  for i, def in ipairs(spawns) do
    local id = (def and def.label and tostring(def.label)) or ("#" .. i)
    if type(def) ~= "table" then
      env.info("BanditSpawner: cfg.spawns[" .. i .. "] is not a table; skipping.")
    elseif def.mode ~= "clone" and def.mode ~= "build" then
      env.info("BanditSpawner: spawn '" .. id .. "' has invalid mode '" .. tostring(def.mode) .. "' (must be 'clone' or 'build').")
    elseif def.mode == "clone" and (not def.template or def.template == "") then
      env.info("BanditSpawner: clone spawn '" .. id .. "' is missing a template group name.")
    elseif def.mode == "build" then
      if not def.airframe or def.airframe == "" then
        env.info("BanditSpawner: build spawn '" .. id .. "' is missing an airframe.")
      end
      local count = tonumber(def.count)
      if not count or count < 1 or count > C.MAX_GROUP_SIZE then
        env.info("BanditSpawner: build spawn '" .. id .. "' has invalid count '" .. tostring(def.count) .. "' (must be 1.." .. C.MAX_GROUP_SIZE .. ").")
      end
    end

    if def.payload_from and type(def.payload_from) == "table" then
      for unitType, donorName in pairs(def.payload_from) do
        if type(donorName) ~= "string" or donorName == "" then
          env.info("BanditSpawner: spawn '" .. id .. "' payload_from entry for '" .. tostring(unitType) .. "' is not a donor group name.")
        end
      end
    elseif def.payload_from and type(def.payload_from) ~= "string" then
      env.info("BanditSpawner: spawn '" .. id .. "' payload_from must be a string or a table.")
    end
  end
  -- DCS radio pages have 10 usable item slots (F1-F10); F11/F12 carry the
  -- "previous menu"/"exit" rows. Warn at load if any configured page would
  -- overflow and leave its last items unreachable in the cockpit.
  local function pageCheck(name, n)
    if type(n) == "number" and n > 10 then
      env.info("BanditSpawner: radio page '" .. name .. "' has " .. n ..
               " items but only 10 slots are usable -- split it into submenus.")
    end
  end
  local nBandits, nAO = 0, 0
  for _, def in ipairs(spawns) do
    if type(def) == "table" and def.ao then nAO = nAO + 1 else nBandits = nBandits + 1 end
  end
  if nBandits > 0 and nAO > 0 then
    pageCheck("Bandits", nBandits)
    pageCheck("AO Spawns", nAO)
  else
    pageCheck("bandit list", nBandits + nAO)
  end
  local d, m, a = FTS.cfg.spawn_distances_nm, FTS.cfg.bearing_modes, FTS.cfg.altitude_modes
  pageCheck("distance tier", type(d) == "table" and #d or 0)
  pageCheck("bearing tier", type(m) == "table" and #m or 0)
  pageCheck("altitude tier", type(a) == "table" and #a or 0)
end

-- players already airborne when the script loads
validateSpawnDefs()
Menu.scanPlayers()
env.info("BanditSpawner loaded.")
