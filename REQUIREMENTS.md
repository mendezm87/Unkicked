# Unkicked — requirements

Status key: **done** · **partial** · **open** · **won't**
Last reviewed: 2026-10-01 (UTC) · against live retail build `12.1.0.69933` (Midnight, patch 12.1, Season 2)

This file is the contract. When behaviour changes, change it here first.

---

## What it is for

During a dungeon pull, show which enemy casts **nobody stopped**, what those casts
cost in damage and deaths, and which party members had an interrupt available when
each cast began.

It reports facts. It does not name a culprit — see R-7.

---

## Functional

| # | Requirement | Status |
|---|---|---|
| **R-1** | Detect enemy casts that started and completed, from `SPELL_CAST_START` → `SPELL_CAST_SUCCESS` on the same source GUID + spellID. | done |
| **R-2** | Treat a cast as *stopped* on `SPELL_INTERRUPT`, which covers kicks **and** stuns/silences/knockbacks that break a cast, with the stopping player as source. | done |
| **R-3** | Model each party member's interrupt cooldown from `SPELL_CAST_SUCCESS` on their interrupt spell — **not** `SPELL_INTERRUPT`, because a kick into an immune cast still burns the cooldown. Learn a shorter cooldown only when: it is **below** base; the class tree actually contains a reduction node; and it is **at or above** that talent's floor. Keep the **minimum** observed. Never learn an increase. | done |
| **R-4** | Base cooldowns and the talent-eligibility gate are **generated** from pinned DB2 exports, never hand-maintained. Read the cooldown as `max(RecoveryTime, CategoryRecoveryTime)` — Blizzard stores it in one field or the other and never consistently. | done |
| **R-5** | Classify interruptibility by snapshotting `notInterruptible` from `UnitCastingInfo` on nameplate units at cast start. A caster with no nameplate yields **unknown**, which is displayed as unknown and never silently treated as interruptible. | partial — no whitelist fallback yet, see R-11 |
| **R-6** | A party member under a blocking aura (stun, fear, silence, incapacitate, …) could not have pressed their interrupt. Report that as its own reason, never as a missed kick. Blocking-aura set is generated from `SpellCategories.Mechanic`. | done |
| **R-7** | Never print a verdict. The addon cannot see party-member position relative to the caster, so "their interrupt was up" is the furthest the data goes. | done |
| **R-8** | Attribute damage to a cast by `(sourceGUID, spellID)` within a window after completion, continuing to accumulate for channel and DoT ticks. Flag a cast as contributing to a death when its damage landed on a party member who died within 5s. | done |
| **R-9** | Refund-style talents make the cooldown conditional, so learn **two** values per player — after a connect, and after a whiff — keyed on whether `SPELL_INTERRUPT` followed the spend. | done |
| **R-10** | Mark the first `COLD_START` seconds of combat low-confidence: a kick spent before we had log visibility looks available. | done |
| **R-11** | Curated per-dungeon spellID whitelist as the interruptibility fallback for casters that never get a nameplate. | open |
| **R-12** | Use `LibOpenRaid` addon comms as a ground-truth override for party cooldowns where available, falling back to the inferred model where not. | open |
| **R-13** | End-of-dungeon summary, persisted per run. | open — only a live per-session summary exists |
| **R-14** | Test `GetSpellBaseCooldown(spellID)` in-game for a spell the player does not own. If it returns correct data it handles the `RecoveryTime` / `CategoryRecoveryTime` merge itself and the generated base-CD table can shrink to talent data only. | open |

## Non-functional

| # | Requirement | Status |
|---|---|---|
| **N-1** | No library dependencies in v1. | done |
| **N-2** | Combat-log handler must not allocate per event beyond what it records; spellID lookups go through a reverse index. | done |
| **N-3** | Data files regenerate with one command and commit the source build string, so `git diff` on patch day **is** the changelog. | done |
| **N-4** | Free distribution only. Blizzard's addon policy forbids charging for an addon, so this is never a paid product. Related: Blizzard's trademark guidelines bar a Mark in a product or domain name — "Unkicked" deliberately contains none. | done |
| **N-5** | The cooldown model must be testable without launching the game: a stubbed client plus a synthetic combat-log replay, run under LuaJIT for Lua 5.1 fidelity. | done |

---

## Known limits (accepted, not bugs)

- The combat log only reports events near you. A caster across the room may be
  invisible to the addon entirely.
- Another player's talent loadout cannot be read; inspecting a trait tree returns
  configID `-1`. The tree gives **spec eligibility** only, and the observed-interval
  learning does the real detection.
- Party-member position relative to an enemy is not available, so "they were out of
  range" cannot be distinguished from "they didn't press it".
- Designed for 5-player content. In a 20-player raid the availability model becomes
  noise.

## Verified against live data (build 12.1.0.69933)

Only **two** interrupt cooldown-reduction talents exist in 12.1, found by joining
the class trait trees against the interrupts' spell categories, labels and family
masks:

| Talent | Class | Effect | Floor |
|---|---|---|---|
| Coldthirst (378848) | Death Knight | −3s off Mind Freeze on a successful interrupt (via triggered spell 378849, `Effect 292` = modify cooldown by spell category 88) | 12.0s vs 15s base |
| Honed Reflexes (391271) | Warrior | −10% Pummel cooldown (`aura 108` ADD_PCT_MODIFIER, matched by spell-family mask) | 13.5s vs 15s base |

Every other interrupt has `eligible = false`, meaning an observed interval below
base is a measurement error and must be clamped — not learned.

**Not independently confirmed:** the Honed Reflexes match comes from the generator's
own join and has not been checked against Wowhead or in-game. Coldthirst was
confirmed previously.
