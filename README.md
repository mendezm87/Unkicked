# Unkicked

Lists the enemy casts **nobody stopped** — what they cost in damage, whether anyone
died to them, and which party members had an interrupt available when each cast
began. One report per pull.

Built for 5-player content on retail (Midnight, patch 12.1, Season 2).

```
== pull 7  Tideburn Warlord -- kill  2:14  2 unkicked (1.9m dmg)
  0:41  Tidal Bolt                       1.2m  KILLED Rek-Illidan (1.2m)
        up: Frosty-Illidan, Rek-Illidan  down: Mystia-Illidan  cc: Pand-Illidan
  1:52  Hex Bolt                         640k
        up: Frosty-Illidan, Mystia-Illidan, Pand-Illidan, Rek-Illidan
  -- 1 cast of unknown interruptibility (not yet proven kickable) --
  1:58  Crushing Tide                    310k
```

> **Read this first: it is not an in-game panel.** Patch 12.0.0 made
> `COMBAT_LOG_EVENT_UNFILTERED` unregisterable by addons and turned every fallback
> read — enemy spell id, `notInterruptible`, party auras, cooldown queries — into a
> *secret value* on dungeon and raid maps. There is no way to compute this inside
> the game any more, and the addon part of this repo says so rather than showing an
> empty frame. What still works is the log file the client writes, so Unkicked is a
> **parser that tails `WoWCombatLog.txt` and reports each pull a few seconds after
> it ends**, in a terminal beside the game. See `REQUIREMENTS.md` for the full list
> of what 12.x removed.

---

## Running it

You need a Lua interpreter — nothing else. No libraries, no build step.

**Windows (the gaming PC):** install one, once:

```powershell
winget install DEVCOM.Lua      # or: scoop install luajit
```

Turn logging on in game — `/combatlog` (and advanced combat logging in
Options → Network). **The in-game panel tells you whether you remembered**: its
bottom line reads `log: on`, `log: on, not advanced` or `log: OFF — /combatlog`,
and clicking it turns logging on. `/uk log` prints the same thing with the
reasons. The toggle resets on every logout, so this is the one thing worth
glancing at before you pull. Then:

```powershell
cd path\to\Unkicked
lua parser\unkicked.lua --follow --model
```

### Current pull vs. the whole run

Like a damage meter's segment toggle:

```powershell
lua parser\unkicked.lua --both      # default: each pull, then the run total
lua parser\unkicked.lua --current   # pulls only
lua parser\unkicked.lua --overall   # the run total only
lua parser\unkicked.lua --overall --top 5
```

The run total prints when the run ends — which the log states, so it is the real
end of the dungeon rather than a guess:

```
== overall  Kings' Rest  17:51 in combat  13 pulls  4/4 bosses
  26 unkicked casts  7.1m dmg  no deaths from a proven cast
  -- by spell --
  Wretched Discharge               4.0m   3 casts
  Hex Volley                       1.6m   1 cast
  Spectral Bolt                    974k  13 casts
  -- interrupt available when a cast got through (chances, not blame) --
  Aigirlf-Illidan-US    16 up    0 on cd     2 cc     8 unknown
  Spirtbreaker-Pereno…  11 up   13 on cd     1 cc     0 unknown
  -- worst single casts --
  pull 7   Wretched Discharge         Half-Finished Mummy      1.7m
  120 further casts (22.0m dmg, 2 deaths) not yet proven kickable -- excluded above
```

One instance is one run (`ZONE_CHANGE` says so in the log), so pointing this at
an archive containing several keys gives you one report each plus a file-wide
total. In `--follow` mode a one-line running total is appended after each pull so
the run figure stays visible between pulls.

**Read the player column as chances, not blame.** It counts how often someone's
interrupt was believed up while a cast got through. The log cannot see whether
they were in range of the caster or busy keeping the group alive.

**macOS / Linux:**

```sh
brew install luajit                    # if you do not have it
luajit parser/unkicked.lua --follow --model
```

With no file argument it looks for `WoWCombatLog.txt` in the usual
`_retail_/Logs` locations; pass a path to read a log you already have.

| Option | What it does |
|---|---|
| `--follow`, `-f` | watch a live log, report each pull as it ends |
| `--from-start` | with `--follow`, replay what is already in the file first |
| `--quiet-gap N` | seconds of calm that end a trash pull (default 5) |
| `--min-damage N` | hide chip-damage casts |
| `--model` | append what is believed about each party member's interrupt, and where that number came from |
| `--json` | one JSON object per pull on stdout, for an overlay or a second monitor |
| `--knowledge PATH` | the interruptibility knowledge file (see below) |

## What the log can do that the addon never could

Two things improve offline, because a combat log states what the client refuses to
tell an addon:

- **Which interrupt each party member actually has.** `COMBATANT_INFO` carries the
  spec id, so Survival vs. Marksmanship hunter and Feral vs. Balance druid are
  resolved instead of left unbound.
- **Whether they took the cooldown-reduction talent.** It also lists the trait node
  entries they selected. Inspecting a loadout in game returns configID `-1`; here
  Coldthirst is simply a fact, so a Frost DK's Mind Freeze is modelled at 12s after
  a connect and 15s after a whiff — no inference, no learning.

What gets *worse* offline is interruptibility: the log carries no
`notInterruptible` flag. So a cast is called interruptible only once a
`SPELL_INTERRUPT` has been seen stopping that spell, at which point it is recorded
in `parser/learned-interruptible.lua` and stays known for every future run. Until
then it is reported in a separate **unknown** section — never silently counted as a
missed kick. That file is plain Lua and safe to edit; add `[spellID] = false` to
mark a cast you know cannot be interrupted and it will be filtered out.

That file is **committed as a seed**, not gitignored, so a fresh clone starts with
the spells already proven here rather than learning from zero — a blank file makes
the first run or two under-report. It grows additively on every parse, and your
own entries survive `git pull` unless you edited a line that also changed
upstream.

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
luajit tests/run.lua        # 130 assertions (model + offline parser)
luajit tests/parser.lua     # the offline half on its own
node tools/check-lua.mjs    # block-balance check across the TOC load order
```

`tests/run.lua` hands off to `tests/parser.lua` in a second process, because the
headless host and the test stub define the same client globals. `luajit` is used
rather than `lua` because WoW runs Lua 5.1.

The parser suite replays `tests/fixtures/sample-combatlog.txt`, a synthetic log with
a trash pack and a boss pull in it. It includes a control: strip the Coldthirst
entry out of that log and the same cast reports the Death Knight as *down* instead
of *up*, which is how we know the talent read is doing something.

## In-game commands

These exist, but on a 12.x client the addon has no input: it loads, refuses the
forbidden events, and says so. `/uk why` prints what is blocked and why.

| | |
|---|---|
| `/uk why` | which events are blocked, and whether restrictions are active now |
| `/uk` | toggle the panel |
| `/uk clear` | drop the current list |
| `/uk model` | what the addon believes about each party interrupt right now |
| `/uk data` | which build the generated tables came from |
| `/uk immune` | show casts that were immune to interrupts too |
| `/uk min <n>` | hide casts under *n* damage |
| `/uk lock` | stop the panel being dragged |

## Install

The parser needs no install — clone or unzip anywhere and run it (see
**Running it** above).

The addon half still installs the normal way, to
`World of Warcraft/_retail_/Interface/AddOns/Unkicked`, with no library
dependencies — but on 12.x all it can do is explain why it cannot work. The useful
reason to have it there is that the folder is also the repo, so one copy serves
both.

## Known limits

- The combat log only reports events near you; a caster across the room can be
  invisible to the addon entirely.
- The combat log carries no interruptible flag, so a cast is *unknown* until a
  `SPELL_INTERRUPT` has been seen stopping that spell at least once. Unknowns are
  reported separately, never as missed kicks.
- A pull's report arrives a few seconds after it ends, because silence is the only
  signal that a trash pack is over. Boss pulls are exact — the log brackets them.
- The report lands outside the game. Nothing can push it back into the WoW UI; that
  would need an addon acting on combat data, which is what 12.0 removed.
- Party-member position is unavailable, so being out of range cannot be told apart
  from not pressing the button.
- Designed for 5-player content. In a 20-player raid the availability model becomes
  noise.

See [REQUIREMENTS.md](REQUIREMENTS.md) for the full contract and what is still open.

## Licence

MIT. Free, as Blizzard's addon policy requires — this is not and cannot be a paid
product.
