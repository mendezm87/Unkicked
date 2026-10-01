# Unkicked — requirements

Status key: **done** · **partial** · **open** · **won't**
Where a requirement is met by the offline parser but not by the in-game addon, the
status says **done (offline)** — see “Offline parser” below for why that is now the
only path.
Last reviewed: 2026-10-01 (UTC), offline parser added · against live retail build `12.1.0.69933` (Midnight, patch 12.1, Season 2)

This file is the contract. When behaviour changes, change it here first.

---

## What it is for

For each dungeon pull, show which enemy casts **nobody stopped**, what those casts
cost in damage and deaths, and which party members had an interrupt available when
each cast began.

Delivery is **per pull, a few seconds after it ends, outside the game** — a terminal
or overlay fed by `WoWCombatLog.txt`, not an in-game panel. Patch 12.0 removed the
in-game path entirely; see the warning section below.

It reports facts. It does not name a culprit — see R-7.

---

## Functional

| # | Requirement | Status |
|---|---|---|
| **R-1** | Detect enemy casts that started and completed, from `SPELL_CAST_START` → `SPELL_CAST_SUCCESS` on the same source GUID + spellID. | done (offline) |
| **R-2** | Treat a cast as *stopped* on `SPELL_INTERRUPT`, which covers kicks **and** stuns/silences/knockbacks that break a cast, with the stopping player as source. | done (offline) |
| **R-3** | Model each party member's interrupt cooldown from `SPELL_CAST_SUCCESS` on their interrupt spell — **not** `SPELL_INTERRUPT`, because a kick into an immune cast still burns the cooldown. Learn a shorter cooldown only when: it is **below** base; the class tree actually contains a reduction node; and it is **at or above** that talent's floor. Keep the **minimum** observed. Never learn an increase. | done (offline) |
| **R-4** | Base cooldowns and the talent-eligibility gate are **generated** from pinned DB2 exports, never hand-maintained. Read the cooldown as `max(RecoveryTime, CategoryRecoveryTime)` — Blizzard stores it in one field or the other and never consistently. | done |
| **R-5** | Classify interruptibility without ever guessing: a cast is interruptible only when something proves it, and **unknown** otherwise, displayed as unknown. In game the proof was `notInterruptible` from `UnitCastingInfo` on a nameplate unit; that is now a secret value. Offline the proof is observational — a `SPELL_INTERRUPT` seen stopping that spell, in any log ever parsed. | partial — see P-4; the log carries no interruptible flag, so a spell is unknown until first observed being stopped |
| **R-6** | A party member under a blocking aura (stun, fear, silence, incapacitate, …) could not have pressed their interrupt. Report that as its own reason, never as a missed kick. Blocking-aura set is generated from `SpellCategories.Mechanic`. | done |
| **R-7** | Never print a verdict. The addon cannot see party-member position relative to the caster, so "their interrupt was up" is the furthest the data goes. | done |
| **R-8** | Attribute damage to a cast by `(sourceGUID, spellID)` within a window after completion, continuing to accumulate for channel and DoT ticks. Flag a cast as contributing to a death when its damage landed on a party member who died within 5s. | done (offline) |
| **R-9** | Refund-style talents make the cooldown conditional, so learn **two** values per player — after a connect, and after a whiff — keyed on whether `SPELL_INTERRUPT` followed the spend. | done (offline) |
| **R-10** | Mark the first `COLD_START` seconds of combat low-confidence: a kick spent before we had log visibility looks available. | done (offline) |
| **R-11** | Curated per-dungeon spellID whitelist as the interruptibility fallback. Largely superseded by P-4: the knowledge file is grown from observation instead of curated, so it needs no maintenance and cannot be wrong. | superseded by P-4 |
| **R-12** | Use `LibOpenRaid` addon comms as a ground-truth override for party cooldowns where available, falling back to the inferred model where not. | **won't** — needs an in-game addon receiving comms, which is the path 12.0 closed. Superseded by P-5, which is stronger: a log states the spec and the talents actually taken. |
| **R-13** | End-of-dungeon summary, persisted per run. | open — the parser reports per pull (P-2) and can emit JSON (P-8), but nothing aggregates a run yet |
| **R-14** | Test `GetSpellBaseCooldown(spellID)` in-game for a spell the player does not own. If it returns correct data it handles the `RecoveryTime` / `CategoryRecoveryTime` merge itself and the generated base-CD table can shrink to talent data only. | **void** — cooldown queries are secret under `SecretWhenCooldownsRestricted` (12.0.5) |
| **R-15** | Never attempt to register an event the client forbids. `COMBAT_LOG_EVENT` and `COMBAT_LOG_EVENT_UNFILTERED` are refused up front; every other registration is wrapped so a future restriction costs one feature, not the addon's load. | done |
| **R-16** | Every guarded read goes through `ns.Plain` / `ns.IsSecret` and is never compared, arithmetic'd, or boolean-tested directly. A secret reads as **unknown**. | done |
| **R-17** | State the restriction plainly rather than render an empty panel. `/uk why` reports which events are blocked and whether restrictions are active now. | done |
| **R-19** | A damage event belongs to exactly **one** cast: the most recent cast of that `(sourceGUID, spellID)` that had completed when the hit landed. A death is claimed by exactly **one** cast: the one that hit that player last inside the death window. An enemy recasting the same spell keeps several records inside the 30s attribution window simultaneously, so crediting every match multiplies both the damage total and the death count by the number of overlapping casts. | done |
| **R-20** | A party member is only a roster entry if the actor is a real `Player-*` GUID. Environment and no-source events are written with the null GUID and the literal name `nil` but carry the affiliation flags of the player they concern, which otherwise passes the group test and becomes a nameless extra member in every availability line. | done |
| **R-21** | The panel states whether the client is **writing `WoWCombatLog.txt` right now**, and whether **Advanced Combat Logging** is on. This is the one load-bearing thing the in-game addon can still do on 12.x: the analysis is offline, `/combatlog` silently resets on every logout, and nothing in the default UI says so, so a forgotten toggle costs the whole run. `LoggingCombat()` is **rate limited to 5 calls per 10 seconds shared across every addon and the `/combatlog` command**, and a limited call returns **nil, not false** — so never poll, cache the last good answer, spend at most one call per 5s, and render a limited reply as *stale*, never as *off*. Walking into an instance with logging off prints a reminder **once per zone**, not once per pull. | done |
| **R-18** | Resolve every live `UnitGUID` through `ns.GUID`, which returns nil for a secret. A GUID is only ever used as a table key and indexing a table with a secret is a hard error, not a nil read, so an unusable GUID must mean "no unit" rather than reaching a `t[guid] = v`. | done |

## ⚠ R-1 … R-10 are not reachable on a 12.x client

Verified 2026-10-01. Patch 12.0.0 ("the addon apocalypse") removed the data this
addon is built on. The Lua is sound and the model is tested, but **the client will
not feed it inside the content it was written for**:

| What 12.x took | Consequence |
|---|---|
| `COMBAT_LOG_EVENT_UNFILTERED` and `COMBAT_LOG_EVENT` **cannot be registered** — doing so raises `ADDON_ACTION_FORBIDDEN`. | R-1, R-2, R-3, R-8, R-9, R-10 have **no input at all**. Every cast, damage, death and interrupt-spend signal came from here. |
| `SecretWhenUnitSpellCastRestricted` (12.0.0) — `UnitCastingInfo` / `UnitChannelInfo` / `UNIT_SPELLCAST_*` return **secret values** for any unit that is not the player or their pet. | R-5 cannot work: the enemy `spellID` cannot be compared or used as a table key, and `notInterruptible` cannot be boolean-tested. Every cast reads unknown. |
| `SecretWhenAurasRestricted` (**12.1.0**) — `UnitAura` is secret during combat, encounters, challenge mode and PvP. | R-6 cannot work: a party member's blocking aura cannot be identified. |
| `SecretWhenCooldownsRestricted` (12.0.5) — cooldown queries are secret. | R-14 is void; `GetSpellBaseCooldown` cannot stand in for the generated table. |
| `SecretOnRestrictedMaps` (12.0.5) — restrictions apply on any addon-restricted map: **dungeon, raid, M+, encounter, rated PvP**. | The restrictions cover exactly the content this addon exists for. Open-world is unaffected and useless for the purpose. |

`COMBAT_LOG_MESSAGE` is the sanctioned replacement, but it delivers a
**preformatted message wrapped in a `|K` string** plus a colour. It can be
displayed; it cannot be parsed, counted or reasoned about. It does not restore
any requirement above.

**The log file is untouched.** WoW still writes `WoWCombatLog.txt` with full
fidelity. R-1, R-2, R-3, R-8, R-9 and R-10 are therefore **satisfied offline** — just
not live and not in-game — by the parser in `parser/`, which drives the addon's own
`Core/` through `ns.Cast:Ingest()`. R-5 and R-6 are the two that the file cannot
fully restore: the log carries no interruptible flag (P-4 works around it by proof)
and it carries aura applications but not whether the player could act, which the
generated mechanic table still answers.

## Offline parser

The replacement for the in-game panel. Same model, different feed.

| # | Requirement | Status |
|---|---|---|
| **P-1** | Parse `WoWCombatLog.txt` and drive the unmodified `Core/` model through `ns.Cast:Ingest()`. The clock is the log timestamp, not wall time, so a log replayed later produces identical numbers to one tailed live. | done |
| **P-2** | Report **per pull**, not per dungeon. Boss pulls bracket on `ENCOUNTER_START` / `ENCOUNTER_END`; trash packs open on the first hostile combat event and close after a configurable quiet gap (default 5s). A segment in which nothing of ours happened is dropped rather than numbered. | done |
| **P-3** | Tail a live log (`--follow`), emitting each pull's report a few seconds after the fighting stops. The file is flushed continuously by the client, so this does not need the dungeon to end. | done |
| **P-4** | Interruptibility is **proven, never assumed**. A spell seen being stopped by `SPELL_INTERRUPT` is recorded as interruptible in a persistent knowledge file and stays so for every future run; casts already reported in the open pull are back-filled when the proof arrives. Everything else is reported as unknown, in its own section. The file is plain Lua and hand-editable (`[spellID] = false` asserts an immune cast). It is **tracked in git as a seed** so a fresh clone does not start blank — the first pass over a log proves spells but reports nothing kickable, so a blank file costs a run. | done |
| **P-5** | Read the roster from the log. `COMBATANT_INFO` states each player's **spec id** and the **trait node entries they actually selected** — both unreadable in game on 12.x — so the interrupt each member has is resolved exactly (including the ambiguous classes: Survival vs. Marksmanship hunter, Feral vs. Balance druid) and a cooldown-reduction talent becomes a **fact** rather than an eligibility gate. Where there is no `COMBATANT_INFO` yet (trash before the first boss), membership falls back to combat-log flags and the interrupt stays unbound until a spend is seen. | done |
| **P-6** | When the talent is known from the log, skip the R-3 learning rule entirely — there is nothing left to infer and a mis-measured gap could only make a known-correct number worse. | done |
| **P-7** | Cold start (R-10) applies to the start of the **log**, not of every pull. A log is continuous, so after the opening seconds, not having seen a spend is itself evidence the interrupt is up. | done |
| **P-8** | `--json`, one object per pull on stdout, for feeding an overlay or a second monitor. Name lists are sorted so two reports of the same pull are diffable. | done |
| **P-9** | Advanced combat logging inserts unit fields between the spell params and the suffix, so the damage amount is not at a fixed offset. **Locate the boundary by shape, not by count**: the block always ends `positionX, positionY, uiMapID, facing, level`, and only those three are fractional. Reject a line whose amount is non-numeric *or fractional*. | done — **verified against a real log** |
| **P-11** | A counted offset of 17 was wrong: retail build 12.1.0 (`COMBAT_LOG_VERSION 22`) writes **19** unit fields. 17 landed on `facing`, which is numeric, so the "is it a number" guard passed and every damage event scored a heading in radians. Hence P-9's shape anchor and the fractional check. | done |
| **P-12** | `WoWCombatLog.txt` is written with CRLF endings, which leaves a trailing `\r` on the last field of every line — corrupting any field read from the end, notably `SPELL_AURA_APPLIED`'s `auraType` and therefore the whole CC model. Strip it once in `Session:line`. | done |
| **P-13** | If the log's header says `ADVANCED_LOG_ENABLED,0`, say so loudly in the footer rather than reporting zeroes: without the unit fields there are no damage amounts and no deaths to attribute, so every number in the report would be a quiet lie. The offline half of R-21. | done |
| **P-10** | Aggregate a whole run (per-player totals, worst casts, repeat offenders) rather than only per-pull reports. | open — this is R-13 for the offline path |

## Non-functional

| # | Requirement | Status |
|---|---|---|
| **N-1** | No library dependencies in v1. | done |
| **N-2** | Combat-log handler must not allocate per event beyond what it records; spellID lookups go through a reverse index. | done |
| **N-3** | Data files regenerate with one command and commit the source build string, so `git diff` on patch day **is** the changelog. | done |
| **N-4** | Free distribution only. Blizzard's addon policy forbids charging for an addon, so this is never a paid product. Related: Blizzard's trademark guidelines bar a Mark in a product or domain name — "Unkicked" deliberately contains none. | done |
| **N-5** | The cooldown model must be testable without launching the game: a stubbed client plus a synthetic combat-log replay, run under LuaJIT for Lua 5.1 fidelity. | done |
| **N-6** | The parser must run on the gaming PC with nothing but a Lua interpreter — no rocks, no JSON library, no build step. JSON is hand-emitted for this reason. | done |
| **N-7** | The parser must share the addon's model rather than reimplement it, so a fix lands in one place and the existing suite still covers it. `parser/host.lua` loads `Core/` unmodified. | done |

---

## Known limits (accepted, not bugs)

- **The 12.x restrictions above are the governing limit.** Everything below this
  line was written against an 11.x client and describes limits that would apply
  *if* the data were available.
- The combat log only reports events near you. A caster across the room may be
  invisible to the addon entirely.
- Another player's talent loadout cannot be read; inspecting a trait tree returns
  configID `-1`. The tree gives **spec eligibility** only, and the observed-interval
  learning does the real detection.
- Party-member position relative to an enemy is not available, so "they were out of
  range" cannot be distinguished from "they didn't press it".
- Designed for 5-player content. In a 20-player raid the availability model becomes
  noise.

### Offline-specific

- **The report appears outside WoW.** Nothing can push it back into the game UI —
  that would require an addon acting on combat data, which is the door 12.0 closed.
  One monitor means alt-tabbing between pulls.
- **`/combatlog` must be on**, and advanced combat logging should be on too
  (Options → Network). Without the log file there is no input at all.
- A pull's report arrives **quiet-gap seconds after it ends** (default 5), because
  silence is the only signal that a trash pack is over.
- A spell is reported as unknown-interruptibility until the first time anyone is
  seen interrupting it. The knowledge file closes that gap over a few runs, and the
  report never presents an unknown as a fact.
- The parser needs a Lua interpreter on the machine running it. LuaJIT is what the
  suite runs on; stock Lua 5.1+ also works.

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

The generator also emits, from the same build:

- `ns.SPEC_INTERRUPT` — all 36 specs mapped to the interrupt that spec has, built
  from `ChrSpecialization` × `ChrClasses`. Useless in game (another player's spec is
  unreadable) and exact offline, where `COMBATANT_INFO` states it.
- `ns.TRAIT_CD` — the trait **node entry** ids that grant a reduction, which is the
  identifier `COMBATANT_INFO` reports: `96212` (Coldthirst) and `116924` / `118850`
  (Honed Reflexes, two entries for the same talent). `conditional = true` marks a
  reduction that only pays out on a successful interrupt.

## Verified against a real dungeon log

Build `12.1.0` / `COMBAT_LOG_VERSION 22`, Kings' Rest, 129,216 lines, 4 encounters,
20 `COMBATANT_INFO`, 34 interrupts. This is the first run against a real retail
dungeon rather than the synthetic fixture, and it confirms:

- **Advanced-logging layout** — 19 unit fields, located by tail shape; 0 lines skipped.
- **Damage totals, cross-checked field-for-field against an independent pass:**
  Shadow Barrage 956,803 · Arc Lightning 1,363,197 · Gilded Destruction 1,506,895 —
  all three matched exactly *after* R-19. Before it, Shadow Barrage reported 4.7m.
- **`COMBATANT_INFO` spec + talent read** — all five members resolved to the right
  interrupt with its exact cooldown, marked `from log`.
- **Boss segmentation** — The Golden Serpent, Mchimba the Embalmer, The Council of
  Tribes and King Dazar each bracketed on `ENCOUNTER_START`/`END` with the outcome.
- **Learned interruptibility** — 12 spells proven kickable on the first pass; the
  second pass over the same log reports 26 unkicked casts that the first could not
  classify. This is the designed behaviour, and it means **the first run of a fresh
  install under-reports** until the knowledge file fills in.

**Still unverified:** whether any DB2 table states interruptibility directly.
`SpellInterrupts.InterruptFlags` exists and is populated for 122,170 spells, but the
bit meanings were not confirmed against a known-uninterruptible NPC cast, so it is
not used. Confirming it would replace P-4's observational approach with a generated
table and remove the unknown-interruptibility section from reports.
