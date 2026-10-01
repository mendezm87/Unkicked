-- Unkicked :: parser/knowledge.lua
--
-- Which enemy casts are interruptible.
--
-- WoWCombatLog.txt does not say. In game the answer came from UnitCastingInfo's
-- notInterruptible flag, which 12.0 made a secret value on exactly the maps this
-- tool is for, so neither path has it any more.
--
-- What a log DOES contain is proof by example: if a cast of spell X was ever
-- stopped by a SPELL_INTERRUPT, X is interruptible, permanently and for every
-- future run. So the knowledge file is grown from the logs themselves and kept
-- between runs. Every spell not in it is reported as UNKNOWN, never as
-- interruptible -- the report says which group a cast is in, so a wrong guess is
-- never dressed up as a fact.
--
-- The file is plain Lua and safe to hand-edit; add `[spellID] = false` to mark a
-- cast you know is immune and it will be filtered out.

local M = {}
M.__index = M

local HEADER = [[
-- Unkicked :: learned interruptibility, grown from parsed combat logs.
--   true  = a SPELL_INTERRUPT was observed stopping this spell (proof)
--   false = you asserted by hand that this cast cannot be interrupted
-- Safe to edit. Regenerated additively; hand-written entries are preserved.
return {
]]

function M.load(path)
  local self = setmetatable({ path = path, known = {}, dirty = false, learned = 0 }, M)
  local chunk = loadfile(path)
  if chunk then
    local ok, t = pcall(chunk)
    if ok and type(t) == "table" then
      for k, v in pairs(t) do
        if type(k) == "number" then self.known[k] = v end
      end
    end
  end
  return self
end

-- nil = unknown, true = interruptible, false = asserted immune.
function M:get(spellID) return self.known[spellID] end

-- Called when a SPELL_INTERRUPT proves a spell interruptible.
function M:observe(spellID, spellName)
  if spellID == nil or self.known[spellID] ~= nil then return false end
  self.known[spellID] = true
  self.names = self.names or {}
  self.names[spellID] = spellName
  self.dirty = true
  self.learned = self.learned + 1
  return true
end

function M:save()
  if not self.dirty or not self.path then return false end
  local ids = {}
  for id in pairs(self.known) do ids[#ids + 1] = id end
  table.sort(ids)
  local f, err = io.open(self.path, "w")
  if not f then return false, err end
  f:write(HEADER)
  for _, id in ipairs(ids) do
    local name = self.names and self.names[id]
    f:write(("  [%d] = %s,%s\n"):format(id, tostring(self.known[id]),
      name and ("  -- " .. name) or ""))
  end
  f:write("}\n")
  f:close()
  self.dirty = false
  return true
end

return M
