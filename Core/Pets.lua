-- Unkicked :: Pets.lua
--
-- Which player a pet belongs to, so a pet's interrupt is the OWNER's interrupt.
--
-- This exists because of a real, measured hole. A warlock does not cast Spell
-- Lock; his felhunter does. Every spend therefore arrives with a Pet-* source
-- GUID, which is not in Kick.players, so the spend was dropped on the floor --
-- and the warlock was reported "interrupt up" for every cast that got through in
-- the whole key. Voidscar Arena +10 (2026-10-01): Dipndøtz's Maashon pressed
-- Spell Lock three times and connected three times, and the report still said
-- `Dipndøtz 24 up / 0 on cd`. That is the healer bug in a different costume --
-- blame for a button we never saw pressed because we were watching the wrong
-- unit.
--
-- Two independent sources of truth, both used:
--
--   * ownerGUID -- the SECOND field of the advanced-logging block, present on
--     every pet line that carries one (SPELL_CAST_SUCCESS does). Authoritative
--     and needs no history: a log that starts mid-pull still names the owner.
--   * SPELL_SUMMON -- srcGUID summons dstGUID. Covers lines with no advanced
--     block, and is what tells us a pet was (re)summoned after dying.
--
-- In game there is no combat log on 12.x, so neither is available and the map is
-- built from unit tokens instead: UnitGUID("partyNpet") and its owner partyN.
-- Those are plain reads, never secret values.

local ADDON, ns = ...

local Pets = {}
ns.Pets = Pets

local owners = {}     -- petGUID  -> ownerGUID
local byName = {}     -- pet name -> ownerGUID
local dead = {}       -- ownerGUID -> true once we SAW their pet die un-resummoned

Pets.owners = owners
Pets.byName = byName

function Pets:Wipe()
  owners, byName, dead = {}, {}, {}
  self.owners, self.byName = owners, byName
end

-- Record a pet -> owner link. Safe to call repeatedly with the same pair; a
-- resummon is a NEW pet GUID with the same name and owner, which is exactly why
-- the name map is kept alongside the GUID map.
function Pets:Note(petGUID, ownerGUID, petName)
  if not petGUID or not ownerGUID then return end
  if petGUID == ownerGUID then return end
  if ownerGUID == "0000000000000000" or petGUID == "0000000000000000" then return end
  -- An owner is never itself a pet. Deliberately NOT "must be a Player-" here: the
  -- strict read happens where the GUID comes off a log line (logline.ownerOf), and a
  -- mob summoning adds is harmless -- kicker() only ever credits roster members.
  if type(ownerGUID) ~= "string" or ownerGUID:find("^Pet%-") then return end
  owners[petGUID] = ownerGUID
  if petName and petName ~= "" and petName ~= "nil" then byName[petName] = ownerGUID end
  -- A pet that is acting is a pet that is out, whatever we thought before.
  dead[ownerGUID] = nil
end

function Pets:Owner(guid)
  return guid and owners[guid] or nil
end

-- The in-game path: a row's GUID is a secret value during a pull, but its NAME
-- is usually plain, and a party pet's name is readable from its unit token. So
-- the name is the only join available mid-pull.
function Pets:OwnerOfName(name)
  return name and byName[name] or nil
end

-- --------------------------------------------------------------- pet liveness
-- A warlock whose pet is dead cannot interrupt at all. That is a real fact about
-- availability, not a gap in our data -- but ONLY when we actually watched the
-- pet die. A log that begins with the pet already out never shows a summon, so
-- "no summon seen" must mean "assume it is out". We only ever move to "no pet"
-- on an observed death, and back on an observed summon or any pet action.
function Pets:OnDeath(guid)
  local owner = owners[guid]
  if owner then dead[owner] = true end
end

-- true only when we have positive evidence the owner currently has no pet.
function Pets:Missing(ownerGUID)
  return ownerGUID ~= nil and dead[ownerGUID] == true
end

-- ------------------------------------------------------------------- in game
-- Party pets from unit tokens. Called on the roster and pet events; cheap, and
-- the only source available on 12.x where there is no combat log to learn from.
function Pets:Scan()
  if type(GetNumGroupMembers) ~= "function" then return end
  local n = GetNumGroupMembers() or 0
  local units = { { "player", "pet" } }
  if type(IsInRaid) == "function" and IsInRaid() then
    for i = 1, n do units[#units + 1] = { "raid" .. i, "raid" .. i .. "pet" } end
  else
    for i = 1, n - 1 do units[#units + 1] = { "party" .. i, "party" .. i .. "pet" } end
  end
  for _, pair in ipairs(units) do
    local ownerGUID = ns.GUID(pair[1])
    local petGUID = ns.GUID(pair[2])
    local petName = petGUID and type(UnitName) == "function" and UnitName(pair[2]) or nil
    if ownerGUID and petGUID then self:Note(petGUID, ownerGUID, petName) end
  end
end

if ns.On then
  ns.On("GROUP_ROSTER_UPDATE", function() Pets:Scan() end)
  ns.On("PLAYER_ENTERING_WORLD", function() Pets:Scan() end)
  ns.On("UNIT_PET", function() Pets:Scan() end)
end

return Pets
