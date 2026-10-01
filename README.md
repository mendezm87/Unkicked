# Unkicked

An in-game panel that lists the enemy casts **nobody stopped** — what they cost in
damage, whether anyone died to them, and which party members had an interrupt
available when each cast began.

Built for 5-player content on retail (Midnight, patch 12.1, Season 2).

```
Unkicked                              4 casts  118k  1 deaths
* Mind Sear                      62k   Grimm Thrack
  Lightning Bolt                 31k   Grimm
? Shadow Word: Pain              18k   ?
  Fireball                        7k   all down
```

`*` contributed to a death · `?` interruptibility could not be determined

---

## Why an addon and not Warcraft Logs

An addon cannot read Warcraft Logs — but it can read the same raw feed WCL is
built from, live, via `COMBAT_LOG_EVENT_UNFILTERED`. That is better for this
purpose: you want the information during the pull, not after it.

## What it reports, and what it refuses to report

It reports facts. It does **not** print a verdict.

The addon can see every interrupt any party member spends, so it can model whose
kick was up. It **cannot** see where a party member was standing relative to the
caster, so "they were out of range" is invisible to it. A row therefore says
*"Grimm and Thrack had an interrupt available"* and stops there. The human applies
the judgment.

Three things get their own treatment rather than being counted as a missed kick:

- **On cooldown** — the model says their interrupt was down, with the remaining time.
- **Could not act** — they were stunned, feared, silenced or incapacitated.
- **Unknown** — we could not determine which interrupt they have, or the pull was
  young enough that they may have spent it before we had log visibility.

## How the cooldown model works

You cannot read another player's cooldowns, and inspecting their talent loadout
returns configID `-1`. So the model is inferred from the combat log:

- A **spend** is `SPELL_CAST_SUCCESS` on the interrupt spell — not `SPELL_INTERRUPT`.
  A kick thrown into an immune cast still burns the cooldown, and `SPELL_INTERRUPT`
  only tells you it connected.
- A **shorter cooldown is learned** from the gap between two observed spends, under
  three guards: it must be *below* base; the class tree must actually contain a
  cooldown-reduction node; and it must be at or above what that talent can achieve.
  The **minimum** observed value wins, so one mis-measured gap cannot widen the
  estimate. An increase is never learned — a longer gap just means they did not
  press it.
- Refund-style talents make the cooldown **conditional**, so two values are learned
  per player: one for a spend that connected, one for a whiff.

## Keeping the data current

Nothing is hand-maintained. Both data files are generated from pinned
[wago.tools](https://wago.tools) DB2 exports:

```sh
node tools/gen-interrupt-data.mjs --report   # base cooldowns + talent gate
node tools/gen-cc-data.mjs                   # blocking-aura table
```

Each run pins to the current live retail build and writes that build string into
the output, so `git diff` on patch day **is** the changelog. Run it on every `.x`
patch.

One implementation detail worth more than the table it produces: a spell's
cooldown lives in **either** `RecoveryTime` **or** `CategoryRecoveryTime`, never
both consistently. Kick and Wind Shear use the first; Pummel, Mind Freeze, Disrupt
and Muzzle use the second and have `RecoveryTime = 0`. Read one field and half your
table is zeros. The generator takes the max.

### What the generator found

Joining all thirteen class trait trees against the interrupts' spell categories,
labels and family masks on build `12.1.0.69933` turns up exactly **two** interrupt
cooldown-reduction talents in the entire game:

| Talent | Class | Effect | Floor |
|---|---|---|---|
| Coldthirst | Death Knight | −3s off Mind Freeze on a successful interrupt | 12.0s vs 15s |
| Honed Reflexes | Warrior | −10% Pummel cooldown | 13.5s vs 15s |

Everything else is `eligible = false`, which means an observed interval below base
is a measurement error and gets clamped rather than learned.

## Tests

The model runs headless against a stubbed client, so the learning rule, the CC
handling and the damage/death attribution are tested without launching the game:

```sh
luajit tests/run.lua        # 67 assertions
node tools/check-lua.mjs    # block-balance check across the TOC load order
```

`luajit` is used rather than `lua` because WoW runs Lua 5.1.

## Commands

| | |
|---|---|
| `/uk` | toggle the panel |
| `/uk clear` | drop the current list |
| `/uk model` | what the addon believes about each party interrupt right now |
| `/uk data` | which build the generated tables came from |
| `/uk immune` | show casts that were immune to interrupts too |
| `/uk min <n>` | hide casts under *n* damage |
| `/uk lock` | stop the panel being dragged |

## Install

Copy the folder to `World of Warcraft/_retail_/Interface/AddOns/Unkicked`.
No library dependencies.

## Known limits

- The combat log only reports events near you; a caster across the room can be
  invisible to the addon entirely.
- Interruptibility comes from `UnitCastingInfo` on **nameplate** units, because the
  combat log carries no interruptible flag. A caster with no nameplate yields
  *unknown* rather than an assumption.
- Party-member position is unavailable, so being out of range cannot be told apart
  from not pressing the button.
- Designed for 5-player content. In a 20-player raid the availability model becomes
  noise.

See [REQUIREMENTS.md](REQUIREMENTS.md) for the full contract and what is still open.

## Licence

MIT. Free, as Blizzard's addon policy requires — this is not and cannot be a paid
product.
