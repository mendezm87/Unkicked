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
| **R-13** | End-of-dungeon summary, with a current-segment / overall toggle the way a damage meter has one. | done **both ways** — offline per P-10 (`--current` / `--overall` / `--both`), and in-game per R-22. An earlier note here said the in-game panel could not have the toggle "because there is nothing to aggregate on 12.x". **That was wrong**: `C_DamageMeter` aggregates server-side and `Enum.DamageMeterSessionType` (Current/Overall/Expired) ships natively. |
| **R-14** | Test `GetSpellBaseCooldown(spellID)` in-game for a spell the player does not own. If it returns correct data it handles the `RecoveryTime` / `CategoryRecoveryTime` merge itself and the generated base-CD table can shrink to talent data only. | **void** — cooldown queries are secret under `SecretWhenCooldownsRestricted` (12.0.5) |
| **R-15** | Never attempt to register an event the client forbids. `COMBAT_LOG_EVENT` and `COMBAT_LOG_EVENT_UNFILTERED` are refused up front; every other registration is wrapped so a future restriction costs one feature, not the addon's load. | done |
| **R-16** | Every guarded read goes through `ns.Plain` / `ns.IsSecret` and is never compared, arithmetic'd, or boolean-tested directly. A secret reads as **unknown**. | done |
| **R-17** | State the restriction plainly rather than render an empty panel. `/uk why` reports which events are blocked and whether restrictions are active now. | done |
| **R-19** | A damage event belongs to exactly **one** cast: the most recent cast of that `(sourceGUID, spellID)` that had completed when the hit landed. A death is claimed by exactly **one** cast: the one that hit that player last inside the death window. An enemy recasting the same spell keeps several records inside the 30s attribution window simultaneously, so crediting every match multiplies both the damage total and the death count by the number of overlapping casts. | done |
| **R-20** | A party member is only a roster entry if the actor is a real `Player-*` GUID. Environment and no-source events are written with the null GUID and the literal name `nil` but carry the affiliation flags of the player they concern, which otherwise passes the group test and becomes a nameless extra member in every availability line. | done |
| **R-21** | The panel states whether the client is **writing `WoWCombatLog.txt` right now**, and whether **Advanced Combat Logging** is on. This is the one load-bearing thing the in-game addon can still do on 12.x: the analysis is offline, `/combatlog` silently resets on every logout, and nothing in the default UI says so, so a forgotten toggle costs the whole run. `LoggingCombat()` is **rate limited to 5 calls per 10 seconds shared across every addon and the `/combatlog` command**, and a limited call returns **nil, not false** — so never poll, cache the last good answer, spend at most one call per 5s, and render a limited reply as *stale*, never as *off*. Walking into an instance with logging off prints a reminder **once per zone**, not once per pull. | done |
| **R-22** | **The live in-game view is `C_DamageMeter`.** One row per player — interrupts pressed, deaths, damage taken — per pull and per key, with a segment picker on the panel header (`/uk current`, `/uk overall`, and per R-31 a dropdown over every harvested pull) and one chat line after each pull (`/uk pulls` to silence). The run total is the sum of the pulls **inside the keystone window**, deliberately not the `Overall` session, so the in-game number and the offline parser's `--overall` describe the same run (P-19). The panel must state on every refresh that it counts kicks **pressed**, not casts **missed** — the thing the addon is named after is not in this API, and omitting that is the one failure mode worth designing against. | done — **never rendered in a real 12.x client** |
| **R-23** | **In combat every amount is a secret value: it may be displayed but never read.** `FontString:SetText` and `StatusBar:SetValue` are whitelisted to accept one, so the live path hands the raw value to the widget untouched — no colour wrapper, no `k`/`m` shortening, no hiding a zero, no comparing, no summing, since all of those read it. Arithmetic (totals, sorting, the run ledger) runs **only** on a snapshot harvested after combat ended, where the same fields are plain numbers again. | done |
| **R-24** | **Never hand a secret back to the API.** `GetCombatSessionSourceFromType` with a secret GUID errors with *"Secret values are only allowed during untainted"* and takes the whole draw down, so metrics cannot be cross-matched by GUID in combat. `classFilename`, `specIconID`, `isLocalPlayer` and `deathRecapID` are `NeverSecret` and are the only in-combat join keys; an identity key is trusted only when it is **unique in both lists**, because two players of one spec collide and a blank cell beats swapping two players' numbers. | done |
| **R-25** | **The `Deaths` metric is a list of deaths, not players with counts.** One entry per death, and only when `deathRecapID ~= 0`; reading `totalAmount` there gives 0 for someone who died and nothing for someone who did not. Count rows. Also: never hardcode `Enum.DamageMeterSessionType` as 0/1 — the values are not guaranteed and guessing reads a different session than Details! is reading. And after `ResetAllCombatSessions` the Current session can come back **empty mid-fight** while new data lands in a session addressed by id, so `GetCombatSessionFromID` is a required fallback or the panel blanks during combat. | done |
| **R-26** | A row exists for every player who was **there**, not only those who scored on the sorted metric — the row list is the union of the actors across every metric shown, so a healer who kicked nothing appears with an explicit zero. Ranking is **list position**, because the API returns the list already sorted by the metric asked for and the amounts cannot be compared. A pull in which nothing happened is not recorded, so pull numbers stay stable enough to say out loud. The client's own `C_ChallengeMode.GetDeathCount` is reported **beside** our total when the two disagree, never instead of it. | done |
| **R-27** | **The closest thing to a missed kick the live client can produce is a cost, not a count.** `C_DamageMeter` will never say what an enemy was casting or whether it could be interrupted — but the `DamageTaken` drill-down *does* name the spell that hit each player, and the offline parser has already **proven** which spell ids are interruptible (P-4). Mirror that knowledge into `Data/Interruptible.lua` on every parse and intersect the two: the `kickable` column is how much of the damage a player ate came from a spell somebody could have stopped. It must be labelled as damage, never as a number of missed casts — it cannot tell how many casts there were, nor whether a given one was kicked and a later one was not. Out-of-combat only (it needs a readable GUID), so it lands when the pull ends. | done — **never rendered in a real 12.x client** |
| **R-28** | **The header row and the data rows share one column geometry, laid out once.** They drifted apart and the header — a single right-justified string anchored at row one's y — was drawn directly on top of the first player, which is what the panel actually looked like in game. The header is its own frame on its own line, with a full row of clearance, and a test asserts the two anchors differ. | done — **fixes a defect seen in a real client screenshot** |
| **R-29** | **Per-pull totals only exist inside a keystone** — `harvest()` bails when no run is open, so outside a key nothing is ever recorded. The Current session therefore is **not** "pull 1"; it is whatever Blizzard has accumulated since the last meter reset, which on a real run was 24:18 of whole-dungeon totals under a label claiming it was the first pull. Outside a key the panel labels it `session (no key)` and the footer says per-pull totals start at `CHALLENGE_MODE_START`. | done |
| **R-30** | **A spec with no interrupt is a fact, not a gap, and is never a missed chance.** Midnight removed the interrupt from every healing spec except Restoration shaman (Wind Shear): Holy paladin lost Rebuke, Mistweaver lost Spear Hand Strike, Preservation lost Quell. `ns.SPEC_INTERRUPT` therefore carries `spellID = false` for those specs — plus Restoration druid and Discipline/Holy priest, who never had one — and `Kick:StateAt` answers `none`, which is dropped from the availability table entirely rather than counted as `ready`. Binding by **class alone** is not safe for the local player either: paladin has exactly one interrupt, so the single-candidate shortcut handed Rebuke to a Holy paladin; for `player` the spellbook is readable and is the authority, including when the answer is "you have none". | done |
| **R-31** | **The segment is a picker, not a toggle.** The panel heading opens a dropdown listing every segment it can draw — the live session, the keystone total, and **each harvested pull**, plus any of Blizzard's own past combat sessions reachable through `GetAvailableCombatSessions` / `GetCombatSessionFromID`. A two-state toggle (R-22) could reach the live view and the run total and nothing else, so a pull could not be looked at once the next one started. Right-clicking the heading still cycles; `/uk segments` lists the same set and `/uk pull <n>` selects one. Three rules this has to obey: a segment addressed **by id** has no per-spell drill-down (there is no by-id variant of `GetCombatSessionSourceFromType`), so it is served nothing rather than the Current session's spells under another heading; a stored key naming a pull that no longer exists (a key since reset) falls back to the live segment and **says so**, because an empty table under "pull 7" is worse than either truth; and a harvest flagged `wholeRun` is labelled **whole key**, never "pull 1" (R-29). Inside a key there is usually exactly **one** selectable pull — secrets lift on leaving the restricted map, not on leaving combat — and the list says that rather than looking like a missing feature. | done — **never rendered in a real 12.x client** |
| **R-32** | **Every column is a sort control.** Clicking a column heading in the panel sorts by it; clicking the same heading again flips the direction. The stored choice persists (`ns.db.sort`), `/uk sort <col> [asc|desc]` reaches the same place, and the sorted heading carries a `v`/`^` so the order has a label on it. The hard part is that a value cannot be *read* during a pull: comparing two secret amounts errors. So there are two orderings — the plain value out of combat, and **list position** in combat, because the API returns each metric already sorted by that metric and reversing a list of positions still reads nothing. Three refusals are mandatory: a column whose values are all empty (`kickable` during a pull) shows a **dash, not an arrow**, and the footer says why; a `name` sort is refused outright when any name is secret, since a name can be unreadable independently of the numbers beside it (observed on the Voidscar +10); and a deaths count that could only be joined by class+spec icon comes back **blank rather than wrong** when a player appears in the Deaths list twice, so he sorts with the zeroes mid-pull and rises to the top once the GUID is readable. | done — **never rendered in a real 12.x client** |
| **R-33** | **A pet's interrupt is its owner's interrupt.** A warlock does not cast Spell Lock — his felhunter does — so every spend arrives with a `Pet-*` source that is not in the roster. Unattributed, it was dropped: on the Voidscar Arena +10 the report said `Dipndøtz 24 up / 0 on cd` for a key in which the demon spent and connected Spell Lock three times. That is R-30's fault aimed at the wrong unit — blame for a cooldown we watched him burn. Ownership is resolved from **two** log sources, both used: the advanced block's `ownerGUID` (second field, present on every pet cast line, so one line is enough with no summon history) and `SPELL_SUMMON`, which also tells us about resummons. In game there is no combat log, so the map is built from `UnitGUID("partyNpet")` instead and the pet's **name** is the only join that survives a pull — a row's guid is secret even when the name beside it is plain. Three rules: the surviving merged row must carry the **player's** identity, because the pet usually sorts above him (the Interrupts list is sorted by kicks and the demon pressed them all); merging reads the amounts, so mid-pull the pet keeps its own row and is **relabelled** `Owner (pet)` rather than folded; and a warlock's own binding must ask the **pet** spellbook (`IsSpellKnown(id, true)`), since `IsPlayerSpell(19647)` is false for a spell the demon owns and would report him as having no interrupt. A pet that we **watched die** means `StateAt` answers `none, pet dead` — but silence never does: a log opening with the demon already out shows no summon, so absence of evidence is not absence of a pet. | done — **never rendered in a real 12.x client** |
| **R-34** | **A kickable column that measured nothing must not read as a measured zero.** On the Ruby Life Pools +10 the column showed `0` for all five players in the run view and **blank** in the live view — the same unknown, rendered two different ways, and neither of them true. Three causes stacked: the live view never computes the figure at all (`Meter:Rows` has no drill-down); the run total initialised `kickable = 0` and summed `(r.kickable or 0)`, so pulls that never measured anything accumulated into a hard zero; and `Data/Interruptible.lua` held 29 spell ids learned from Kings' Rest, the Blinding Vale and Voidscar, **none of which occur in Ruby Life Pools** — so even a drill-down that worked perfectly would have matched nothing. An unmeasured total is now `nil` and renders blank, a drill-down that ran and matched nothing stays a real `0`, and a column that is blank for every row says which of the two reasons it is in the footer. The data file is regenerated from every parse, so a dungeon the parser has never seen starts blank by construction and fills in on the next parse — that is the learning curve, not a fault. | done — **never rendered in a real 12.x client** |
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

`C_DamageMeter` **is** a real replacement, for part of it — see R-22. The server
aggregates and returns a finished, already-sorted list, and `Enum.DamageMeterType`
includes `Interrupts`, `Deaths`, `DamageTaken` and a per-spell breakdown. So
*interrupts pressed per player, per pull and per key* is live and in-game again.
What it does **not** restore is R-2 and R-5 — whether an enemy cast was
interruptible, and which cast got through. Those are not in the API at all, so the
addon's namesake stays an offline answer.

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
| **P-10** | Aggregate a whole **run** beside the per-pull reports: totals, by spell, by caster, worst single casts, and per player how often their interrupt was believed available when something got through. A run is **one instance, read from the log** — `ZONE_CHANGE` states the instance id, name and difficulty and the next one ends it — so a file holding three keys yields three overall reports rather than one blend, and a file-wide total is printed as well. A zone walked through with no pulls is not a run; a log that begins mid-dungeon gets one implicit run rather than losing its pulls. Selected with `--current` / `--overall` / `--both` (default), and emitted as JSON tagged `"overall":true`. | done |
| **P-14** | A death caused by a cast that is not yet **proven** kickable (P-4) is excluded from the unkicked totals but **counted and stated separately** — `unknownDeaths`. Dropping it let the overall print "no deaths caused" for a run whose own pull reports said `KILLED` twice, which is the summary contradicting the detail. Observed on the Kings' Rest log: both deaths came from Shadow Barrage, which the seed cannot yet prove. | done |
| **P-22** | `--pull N` (or `--pull 3,5`) prints only the named pulls. The parser cannot re-select a pull it has already printed, so the CLI equivalent of R-31's dropdown is a flag. A pull filtered out of the **printing** is still counted into the run total: "show me pull 7" asks to read one pull, it does not claim the other nine did not happen, and the `== overall` line is byte-identical with and without the flag. | done — **verified against the Blinding Vale +13 log** |
| **P-23** | Every cell stays inside its column. A spell name is truncated to its field like every other string — an untruncated `Xal'atath's Bargain: Devour the Unworthy` ran straight into the caster column in the Voidscar +10 — and a realm-qualified player name is truncated in the model footer rather than shoving the spec, spell and cooldown columns right. The model footer prints **once**, and again only when a spec, cooldown or talent read actually changes, instead of repeating the same five rows under all ten pulls of a key. | done — **verified against both October keys** |
| **P-24** | `--sort COL` orders the overall tables, with `--asc` / `--desc` for direction. A column name applies to **every table that has it** — `--sort damage` orders both the by-spell table and the worst-cast list — and the requested column is only the *first* key, so ties still break the way that table always broke them and the order stays stable between runs. A text column defaults to A-Z and a number to largest-first. A reordered section **names its order** in its heading (`-- by spell -- casts desc`), because a table that is not in its default order is otherwise indistinguishable from one that is wrong. An unknown column is refused at the argument with the real list, never silently ignored. Sorting changes what is **printed**, never what was counted: the `== overall` line is identical with and without the flag. Columns: spells/casters `damage casts deaths name`, players `up cd cc unknown name`, worst casts `damage deaths pull spell`. | done — **verified against the Blinding Vale +13 log** |
| **P-25** | The model footer marks a pet interrupt as such (`Spell Lock 24.0s from log (pet)`), so a cooldown the warlock never presses himself does not read as one he does. | done — **verified on the Voidscar +10 log: `Dipndøtz 24 up / 0 on cd` became `19 up / 5 on cd`** |
| **P-15** | The per-player column in the overall report counts **chances, not failures**, and says so in its header. R-7 still applies: the log cannot see whether a player was in range of the caster or busy keeping the group alive, so an availability count must never be rendered as a blame table. | done |

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

## Healer interrupts in Midnight (corroborated by log, 2026-10-02)

Every healing spec except Restoration shaman lost its interrupt this expansion.
The evidence in our own logs, for the one case a log could settle:

| Log | Spec | Rebuke casts |
|---|---|---|
| 08/14 Kings' Rest | Wafflezealot, **Protection** paladin (66) | 6 |
| 10/01 Blinding Vale +13 | Wafflezealot, **Holy** paladin (65) | 0 |
| 10/01 Voidscar Arena +10 | Wafflezealot, **Holy** paladin (65) | 0 |

Same player, same character, interrupt disappears with the spec change — while
the model credited him an available kick for **all 98** casts that got through
those two keys. No Mistweaver, Preservation or Restoration druid has appeared in
any log yet, so for those three the removal is taken from the user's statement
and not independently confirmed here.

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

| **P-16** | The overall counts **every** party death in the run, not only the ones a cast can be blamed for, and states the difference (`N further deaths from no tracked cast ... M of T accounted for`). A melee killing blow or a ground effect is nobody's missed kick, but a run total that silently omits it disagrees with the death count any damage meter shows for the same fight. Observed on The Blinding Vale log: 6 party deaths, 5 attributable to a cast. | done |
| **P-17** | Two distinct spell ids may carry the same name, so the by-spell table labels a collision with its spell id. The Blinding Vale ships two `Light Bolt`s (`1235616` and `1238063`); without the id the two rows read as one row duplicated by a bug. | done |
| **P-18** | A cooldown-reduction talent is asserted as a **value** only when the generator traced it to a real cooldown-modifying effect against the interrupt's spell category (`match = "category"`, i.e. Coldthirst). A weaker class-mask/label match sets the **learning floor** and marks the player eligible, leaving the modelled cooldown at base. This follows the stated rule — correct a cooldown only if a talent exists *and* a shorter interval is actually observed — and it is what the real log forced: an Arms warrior holding Honed Reflexes node entry `118850` had a shortest observed Pummel interval of **14.88s across 22 presses**, not the 13.5s the heuristic asserted. Asserting it marks a kick available ~1.5s early. | done |

| **P-19** | **Mythic+ only, by default.** A report covers the pulls inside a key window and nothing else. The keystone is the only proof of a key: `CHALLENGE_MODE_START` states the level and opens the window, `CHALLENGE_MODE_END` closes it, and difficulty 23 in `ZONE_CHANGE` is *not* evidence — the Kings' Rest log is difficulty 23 with no `CHALLENGE_MODE_START` at all. Pulls in the instance before the stone goes in, and after the key ends, are outside the window. A stale `CHALLENGE_MODE_END` for a key abandoned before the log began (all-zero fields, no `START` in front of it) is ignored rather than closing a window that never opened. Skipped segments are **named** in the footer, because a report that silently omits five pulls looks broken even when it is right. `--all` restores every segment. Raids are out of scope for now. Interruptibility knowledge is still learned from the whole file — learning is additive and free. | done |
| **P-21** | A no-source event is written with the null GUID and the **literal string `nil`** as its name. Reports fall back on `name or "?"`, so without rejecting it the parser prints a mob called `nil` — seen against every Unstable Singularity in the Voidscar +10. | done |
| **P-20** | Pulls are numbered **within their run** (`pull.runIndex`), so "pull 3" is the third pull of this key rather than the third segment in the file. Without this, open-world fighting before the key shifts every number in the report. | done |
| **R-19** | The in-game panel must not look broken on a client where it cannot work. With no combat-log feed the frame **collapses** to its header plus the logging-state line instead of showing a dozen rows that can never fill, says `no combat log in 12.x` in the footer, and prints one line at login stating that it is on screen and how to recentre it (`/uk reset`) — "I saw nothing in the UI" must be distinguishable from "it failed to load". | done — **never rendered in a real 12.x client** (no WoW install on the build machine); covered headlessly only: the file loads, the frame is created and shown, Refresh survives empty data, and the toggle/reset commands work. |

| **R-21** | A pull is the **difference between two readable snapshots** of the same `C_DamageMeter` session, never a snapshot itself. The Current session does not reset between pulls inside a keystone, so recording each harvest whole counts pull one again in every later pull. A session whose totals or clock went *backwards* is a different session and its snapshot stands alone. | done |
| **R-22** | Amounts on a restricted map stay secret for the **whole map**, not merely while in combat, so a key can end with zero successful harvests. The live segment must therefore never be labelled `pull N` — it is `key so far` / `key total` / `session (no key)` — and completing the key must harvest and report whatever became readable then, even if that is the entire run as one segment. Refused harvests are counted (`/uk audit`). | done |
| **R-23** | A metric a player is absent from means **zero**, but only when the join was definitive (a GUID match). An identity match that collided stays blank: a confident wrong zero is worse than an empty cell. | done |
| **R-24** | **One actor, one row.** A pet that is resummoned returns as several rows sharing one name (a felhunter's three Spell Locks in the Voidscar +10 arrived as `Pet-…-417-01/02/04`, amount 1 each — Blizzard's own meter draws them that way). Rows carrying the same readable name are merged and their amounts summed. Merging *reads* the amounts, so it happens only when they are plain; in combat the duplicates stand. | done |
| **R-25** | **Plainness is decided per value, not per table.** A row can return a readable amount beside an unreadable name. A single global flag made the whole panel render raw (`77011323` where `77.0m` belonged), so each cell asks `IsSecret` about its own value. | done |
| **R-26** | The panel's row budget must fit the **group plus its pets**, and the frame is sized to the rows actually shown, not to the cap. Six slots let three duplicate pet rows push the one member who died off the list entirely — which read as the panel undercounting deaths when the count was right. | done |
| **R-27** | `src.guid` from `C_DamageMeter` is **secret even when the amounts beside it are plain** (measured after the Voidscar +10: `/uk audit` printed readable names and totals on rows whose guid was unreadable). A drill-down gated on a plain guid therefore never runs at all, so the secret value is handed back under `pcall` and each refusal is **counted** and reported by `/uk audit`, rather than the `kickable` column staying blank with no explanation. | open — the drill-down has never succeeded in a real client |

## Verified against a real keystone, in game — The Blinding Vale +13 (2026-10-01)

The panel's live per-player interrupt counts, read from `C_DamageMeter` after the
key, matched `SPELL_INTERRUPT` in that key's own combat log **exactly**:

| Player | Panel | Log |
|---|---|---|
| Yoyiek-Mok'Nathal | 26 | 26 |
| Tun-BleedingHollow | 19 | 19 |
| Fluffipriest-Sargeras | 12 | 12 |
| Tutte-Drakkari | 9 | 9 |
| Wafflezealot-Dalaran | (blank) | 0 |

Session clock 24:18 against the parser's 24:11 in combat — i.e. the Current
session spanned the **whole key** (R-21), and the panel's `pull 1 24:18` was
whole-run data under a pull label.

**Open:** the same screenshot showed **3 deaths** where the log has **6** — all
three of Tun's are missing, while his 19 kicks joined correctly. Cause unknown:
Blizzard's `Deaths` list, the `deathRecapID ~= 0` filter, or the join. `/uk audit`
dumps the raw rows so the next key answers it.

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

## Verified against a Season 2 log — The Blinding Vale +13

Build `12.1.0` / `COMBAT_LOG_VERSION 22`, The Blinding Vale, difficulty 23, keystone
+13, 271,125 lines, 4 encounters (4/4 kills), 25 `COMBATANT_INFO`, 66 interrupts,
89 interrupt spends. Current-season content on the operator's own client, so the
format checks here are not inherited from an older log.

- **No lines skipped**; the 19-field advanced layout holds on current content.
- **Run boundary read from `ZONE_CHANGE`** — instance 2859 at 16:44, closed at 17:13,
  24:11 in combat across 10 reported pulls, with the key level from `CHALLENGE_MODE_START`.
- **All five specs resolved from `COMBATANT_INFO`** — Shadow/Silence, Arms/Pummel,
  Balance/Solar Beam, Holy/Rebuke, Guardian/Skull Bash.
- **80 unkicked casts / 24.3m damage / 4 deaths**, with 164 further casts still
  unproven. Cross-checked: 6 party deaths in the log, 5 attributable to a cast.
- **Honed Reflexes was found in a real loadout and its asserted effect disproved**
  — see P-18. The talent node entry is genuinely selected by an Arms warrior, but the
  −10% Pummel cooldown it was credited with is not supported by 22 observed presses.
  In this log the correction changed no verdict (the shortest interval sits inside the
  epsilon of base either way), but it removes a systematic ~1.5s early-availability bias.
- **The CC column read 0 for every player, and that is correct here.** The log does
  contain a real blocking aura on four party members (`1238294` Disorienting Screech,
  mechanic `DISORIENTED`, 17:06:35 → 17:06:38), but no proven-kickable cast completed
  inside that window. The column is therefore still **untested against a coincidence**
  of CC and an unkicked cast.

**Still unverified:** the Coldthirst two-bucket model against a real Death Knight —
no DK has appeared in either real log. `SpellInterrupts.InterruptFlags` is likewise
still unconfirmed (see above).
