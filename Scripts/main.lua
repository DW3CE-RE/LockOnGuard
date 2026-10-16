--[[
    LockOnGuard - face the lock-on target while guarding.

    While a player (P1 or P2) is locked on and holding guard, their body is turned toward the target, like
    AI officers do when they circle you. Movement direction, speed and animation stay with the game's own
    guard-walk. When not guarding, nothing is changed.

    Based on (DW3CE_RE-Win64-Shipping.exe):
      * AAppCharacter::ApplyFaceTargetRotation (141758100) turns the body toward the target only for pawns
        possessed by an AAppAIController, so players never get it.
      * Guard-walk: UAppCharMovement::UpdateVelocity (1414416e0) sets movement+0x112B (anim IsShift) for a
        player in motion GUARD (0x10), and UpdateRunStartRotation (141442100) never starts a run in it.
      * Guard: AAppCharacterBase::m_bHoldGuardButton (+0x785, reflected) and tag Ability.State.Guard.
      * Lock-on: AAppCharacterPlayer.ATPCCamera -> GetCameraLockOnTargetObject() -> GetTargetActor().
]]

local Config = require("config")

local function dbg(fmt, ...)
    if Config.Debug then print(string.format("[LockOnGuard] " .. fmt .. "\n", ...)) end
end

local PLAYER_INDICES = { 0, 1 }  -- m_ePlayerID: P1, P2 (split screen)

------------------------------------------------------------------------
-- Owned gameplay tags (ASC ExplicitTags, the same data AAppCharacter::HasAbilityTag 141746710 reads)
------------------------------------------------------------------------
local ASC_CLASS = "/Script/GameplayAbilities.AbilitySystemComponent"
local CustomPropsReady = false

local function TryRegisterCustomProperties()
    if CustomPropsReady then return true end
    local cls = StaticFindObject(ASC_CLASS)
    if not (cls and cls:IsValid()) then return false end
    local ok, err = pcall(function()
        RegisterCustomProperty({
            ["Name"] = "LOG_ExplicitTags",
            ["Type"] = PropertyTypes.ArrayProperty,
            ["BelongsToClass"] = ASC_CLASS,
            ["OffsetInternal"] = 0x1318,
            ["ArrayProperty"] = { ["Type"] = PropertyTypes.NameProperty },
        })
        RegisterCustomProperty({
            ["Name"] = "LOG_ParentTags",
            ["Type"] = PropertyTypes.ArrayProperty,
            ["BelongsToClass"] = ASC_CLASS,
            ["OffsetInternal"] = 0x1328,
            ["ArrayProperty"] = { ["Type"] = PropertyTypes.NameProperty },
        })
    end)
    if not ok then dbg("RegisterCustomProperty failed: %s", tostring(err)) end
    CustomPropsReady = ok
    return ok
end

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------
local Enabled = Config.Enabled
local Clock = 0.0
local NextPlayerSearch = 0.0
local GameplayStatics = nil

-- One entry per player index: { player, facing, cmc, savedOrient, savedDesired, reason }
local Slots = {}
for _, idx in ipairs(PLAYER_INDICES) do Slots[idx] = { reason = "" } end

local function IsValidObj(o)
    return o ~= nil and o.IsValid ~= nil and o:IsValid()
end

local function IsDead(c)
    local ok, dead = pcall(function() return c.m_bDead end)
    return ok and dead == true
end

------------------------------------------------------------------------
-- Facing override (per slot)
------------------------------------------------------------------------
local function EndFacing(slot, reason)
    if not slot.facing then return end
    if IsValidObj(slot.cmc) then
        if slot.savedOrient ~= nil then slot.cmc.bOrientRotationToMovement = slot.savedOrient end
        if slot.savedDesired ~= nil then slot.cmc.bUseControllerDesiredRotation = slot.savedDesired end
    end
    slot.facing = false
    slot.cmc = nil
    dbg("facing OFF (%s)", reason or "")
end

local function BeginFacing(slot, player)
    local cmc = player.CharacterMovement
    if not IsValidObj(cmc) then return nil end
    if not slot.facing then
        slot.savedOrient = cmc.bOrientRotationToMovement
        slot.savedDesired = cmc.bUseControllerDesiredRotation
        slot.cmc = cmc
        slot.facing = true
        dbg("facing ON")
    end
    -- Stop the movement component from turning the body itself while it is aimed at the target.
    if cmc.bOrientRotationToMovement then cmc.bOrientRotationToMovement = false end
    if cmc.bUseControllerDesiredRotation then cmc.bUseControllerDesiredRotation = false end
    return cmc
end

------------------------------------------------------------------------
-- Player lookup. After a death / checkpoint restart the game spawns a new character while the old one can
-- stay "valid" for a while, so re-scan every second and keep the live, possessed character per index.
------------------------------------------------------------------------
local function RefreshPlayers()
    if Clock < NextPlayerSearch then return end
    NextPlayerSearch = Clock + 1.0

    local best, bestScore = {}, {}
    for _, c in ipairs(FindAllOf("AppCharacterPlayer") or {}) do
        if IsValidObj(c) then
            local ok, idx = pcall(function() return c.m_ePlayerID end)
            if ok and Slots[idx] then
                local okC, ctrl = pcall(function() return c.Controller end)
                local score = ((okC and IsValidObj(ctrl)) and 2 or 0) + (IsDead(c) and 0 or 1)
                if score > (bestScore[idx] or -1) then best[idx], bestScore[idx] = c, score end
            end
        end
    end

    for idx, slot in pairs(Slots) do
        local new = best[idx]
        local old = slot.player
        local changed = (new == nil) ~= (old == nil)
            or (new ~= nil and old ~= nil and new:GetAddress() ~= old:GetAddress())
        if changed then
            EndFacing(slot, "player changed")
            if new then dbg("P%d: %s", idx + 1, new:GetFullName()) end
        end
        slot.player = new
    end
end

------------------------------------------------------------------------
-- Checks
------------------------------------------------------------------------
local function GetLockOnTarget(player)
    local ok, target = pcall(function()
        local cam = player.ATPCCamera
        if not IsValidObj(cam) then return nil end
        local lockObj = cam:GetCameraLockOnTargetObject()
        if not IsValidObj(lockObj) then return nil end
        local t = lockObj:GetTargetActor()
        if IsValidObj(t) then return t end
        return nil
    end)
    if ok then return target end
    return nil
end

local function GetOwnedTags(character)
    local tags = {}
    local ok = pcall(function()
        local asc = character.AbilitySystemComponent
        if not IsValidObj(asc) then return end
        local function collect(arr)
            if arr == nil then return end
            arr:ForEach(function(_, elem)
                local name = elem:get()
                if name then tags[name:ToString()] = true end
            end)
        end
        collect(asc.LOG_ExplicitTags)
        collect(asc.LOG_ParentTags)
    end)
    if not ok then return nil end
    return tags
end

local function FirstTag(tags, list)
    if tags == nil then return nil end
    for _, t in ipairs(list) do
        if tags[t] then return t end
    end
    return nil
end

local function IsGuarding(player, tags)
    local ok, held = pcall(function() return player.m_bHoldGuardButton end)
    if ok and held then return true end
    return tags ~= nil and tags["Ability.State.Guard"] == true
end

local function ShouldFace(player)
    if not Enabled then return false, "disabled" end
    if IsDead(player) then return false, "dead" end
    local tags = GetOwnedTags(player)
    if not IsGuarding(player, tags) then return false, "not guarding" end
    local skip = FirstTag(tags, Config.SkipTags)
    if skip then return false, "tag " .. skip end
    local target = GetLockOnTarget(player)
    if not target then return false, "no lock-on target" end
    if IsDead(target) then return false, "target dead" end
    return true, "guarding, locked on", target
end

------------------------------------------------------------------------
-- Rotation: turn toward the target at the character's own movement rotation rate.
------------------------------------------------------------------------
local function NormalizeAxis(a)
    a = a % 360.0
    if a > 180.0 then a = a - 360.0 end
    return a
end

local function GetDeltaSeconds(worldContext)
    if not IsValidObj(GameplayStatics) then
        GameplayStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    end
    if IsValidObj(GameplayStatics) then
        local ok, dt = pcall(function() return GameplayStatics:GetWorldDeltaSeconds(worldContext) end)
        if ok and type(dt) == "number" and dt > 0 and dt < 0.5 then return dt end
    end
    return 1.0 / 60.0
end

local function FaceTarget(player, cmc, target, dt)
    local myLoc = player:K2_GetActorLocation()
    local tLoc = target:K2_GetActorLocation()
    local dx, dy = tLoc.X - myLoc.X, tLoc.Y - myLoc.Y

    local rot = player:K2_GetActorRotation()
    local delta = NormalizeAxis(math.deg(math.atan(dy, dx)) - rot.Yaw)
    local okR, rate = pcall(function() return cmc.RotationRate.Yaw end)
    if okR and type(rate) == "number" and rate > 0 then
        local step = rate * dt
        if delta > step then delta = step elseif delta < -step then delta = -step end
    end
    if math.abs(delta) >= 0.01 then
        player:K2_SetActorRotation({ Pitch = rot.Pitch, Yaw = rot.Yaw + delta, Roll = rot.Roll }, false)
    end
end

------------------------------------------------------------------------
-- Per-frame update (game thread)
------------------------------------------------------------------------
local function UpdateSlot(idx, slot, dt)
    local player = slot.player
    if not IsValidObj(player) then
        EndFacing(slot, "no player")
        return
    end
    local should, reason, target = ShouldFace(player)
    if reason ~= slot.reason then
        dbg("P%d state: %s", idx + 1, reason)
        slot.reason = reason
    end
    if not should then
        EndFacing(slot, reason)
        return
    end
    local cmc = BeginFacing(slot, player)
    if cmc then FaceTarget(player, cmc, target, dt) end
end

local function Tick()
    if not TryRegisterCustomProperties() then return end
    local ok, err = pcall(function()
        local dt = 1.0 / 60.0
        for _, slot in pairs(Slots) do
            if IsValidObj(slot.player) then dt = GetDeltaSeconds(slot.player); break end
        end
        Clock = Clock + dt
        RefreshPlayers()
        for _, idx in ipairs(PLAYER_INDICES) do
            UpdateSlot(idx, Slots[idx], dt)
        end
    end)
    if not ok then dbg("tick error: %s", tostring(err)) end
end

if EngineTickAvailable then
    LoopInGameThreadAfterFrames(1, Tick)
else
    LoopInGameThreadWithDelay(16, Tick)
end

------------------------------------------------------------------------
-- Console: "lockonguard" prints the state of each player; "lockonguard on|off|debug" changes it.
------------------------------------------------------------------------
RegisterConsoleCommandHandler("lockonguard", function(FullCommand, Parameters, Ar)
    local arg = Parameters[1]
    if arg == "on" then Enabled = true
    elseif arg == "off" then Enabled = false
    elseif arg == "debug" then Config.Debug = not Config.Debug end

    local lines = { string.format("enabled=%s debug=%s", tostring(Enabled), tostring(Config.Debug)) }
    for _, idx in ipairs(PLAYER_INDICES) do
        local slot = Slots[idx]
        local p = slot.player
        if IsValidObj(p) then
            local t = GetLockOnTarget(p)
            local okG, guard = pcall(function() return p.m_bHoldGuardButton end)
            table.insert(lines, string.format("P%d: facing=%s holdGuard=%s lockOn=%s last='%s'", idx + 1,
                tostring(slot.facing), tostring(okG and guard), t and t:GetFName():ToString() or "none",
                slot.reason))
        else
            table.insert(lines, string.format("P%d: not found", idx + 1))
        end
    end
    for _, l in ipairs(lines) do Ar:Log("[LockOnGuard] " .. l) end
    return true
end)
