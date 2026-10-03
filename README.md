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

> **Read this first: it is two halves, and only one of them is in the game.**
> Patch 12.0.0 made `COMBAT_LOG_EVENT_UNFILTERED` unregisterable by addons and
> turned every fallback read — enemy spell id, `notInterruptible`, party auras,
> cooldown queries — into a *secret value* on dungeon and raid maps.
>
> **In game** you get what `C_DamageMeter` can tell us, which is real and live:
> interrupts **pressed** per player, deaths and damage taken, per pull and for the
> whole key, with a segment picker. That is "who is kicking".
>
> **Out of game** you get the thing the addon is named after. Whether an enemy cast
> was interruptible, and which casts got through, are not in any 12.x API — but they
> are all still in the log file the client writes. So the other half is a **parser
> that tails `WoWCombatLog.txt` and reports each pull a few seconds after it ends**,
> in a terminal beside the game. That is "what got through", and nothing in game can
> answer it. See `REQUIREMENTS.md` for the full list of what 12.x removed.

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

### Mythic+ only

By default a report covers **the pulls inside a key window and nothing else**. The
keystone is the only proof of a key — `CHALLENGE_MODE_START` states the level and
opens the window, `CHALLENGE_MODE_END` closes it. Difficulty 23 in `ZONE_CHANGE` is
not evidence: a plain Mythic dungeon reads identically and has no `START` line at
all. So the trash you cleared in the city on the way there, and the pulls inside
the instance before someone put the stone in, are not in the report.

```powershell
lua parser\unkicked.lua              # mythic+ keys only (default)
lua parser\unkicked.lua --all        # every segment, including open world
```

Anything skipped is named rather than silently dropped:

```
unkicked: not a mythic+ key, skipped -- Silvermoon City (5 pulls, no keystone)  (--all to include)
```

Raids are out of scope for now. Interruptibility knowledge is still learned from
the whole file either way — learning is additive and costs nothing.

### Current pull vs. the whole run

Like a damage meter's segment toggle:

```powershell
lua parser\unkicked.lua --both      # default: each pull, then the run total
lua parser\unkicked.lua --current   # pulls only
lua parser\unkicked.lua --overall   # the run total only
lua parser\unkicked.lua --pull 7    # just pull 7 (the run total still covers them all)
lua parser\unkicked.lua --sort casts        # order the tables by cast count, not damage
lua parser\unkicked.lua --sort damage --desc # worst casts by pure size, ignoring deaths
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
| `--all` | report every segment, not just mythic+ keys |
| `--mplus` | mythic+ keys only (the default) |
| `--model` | append what is believed about each party member's interrupt, and where that number came from |
| `--json` | one JSON object per pull on stdout, for an overlay or a second monitor |
| `--knowledge PATH` | the interruptibility knowledge file (see below) |

### Pulls that survive a logout

A harvested pull used to die with the session: `Meter.pulls` was an in-memory
table and `UnkickedDB` held only settings, so logging out to update the addon
threw away a finished key's whole report and left the dropdown with nothing but
the live view. Pulls, the keystone they belong to, and the **five most recent past
keys** are now stored in `UnkickedDB.history`, written as each pull is harvested
rather than at logout — so a crash or a disconnect keeps them too.

```
> key so far  12:40
  run  12:40  2 pulls
  whole key  1:00  5 kicks
  saved  Ruby Life Pools +10  17:09  8 pulls  2h ago
  saved  The Blinding Vale +13  24:11  1 pull  1d ago
```

A stored key lists its total; select it and its own pulls appear underneath,
because five keys' worth of pulls is a menu taller than the screen. `/uk history`
is the same list in chat.

### Clearing it

A harvested pull cannot be got back by playing again — the session it came from
is gone and its amounts were only readable for the moment we read them. So
clearing is scoped, it reports how much it actually threw away, and the bare
command clears nothing:

| | |
|---|---|
| `/uk forget` | lists the scopes below and their sizes. Clears nothing. |
| `/uk forget saved` | every stored key. The key in progress is untouched. |
| `/uk forget <n>` | one stored key, by its `/uk history` number |
| `/uk forget current` | the pulls harvested in the key in progress |
| `/uk forget all` | both |
| `/uk forget settings` | all of it **and** every setting — a fresh install |

The dropdown offers the same thing without the typing: its last entries are
*forget this stored key*, *clear N stored keys* and *clear N pulls in this key*,
shown only when there is something there to take. Each needs two clicks — the
first arms it and says so — because it sits in the same list as the harmless act
of looking at a different segment.

Two details that are the difference between clearing and corrupting: the file is
rewritten in the same breath rather than at logout, so a clear survives a crash;
and dropping the current key's pulls drops the baseline snapshot with them, so
the next harvest is taken whole instead of being differenced against numbers
that no longer exist.

Four rules keep the stored copy honest, and each is a test:

- **Nothing secret is ever written.** Every field is re-checked through `ns.Plain`
  on the way out. A secret serialised into a file comes back next login as an
  ordinary number — an invented fact that can never again be told from a measured
  one.
- **The schema is versioned**, and a version this build does not know is discarded
  whole rather than half-read into confident zeroes.
- **A restored pull is never counted twice.** The baseline snapshot is stored
  beside the run, so a `/reload` mid-key resumes from it; a session that came back
  from zero is taken whole instead of being subtracted from last login's larger
  numbers.
- **A restored run only resumes while the client says that keystone is still
  running.** Otherwise it goes to the history, where nothing harvests into it.

Caps are 5 keys × 30 pulls × 10 rows, and a malformed stored record is dropped
rather than repaired.

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
- A **pet's interrupt belongs to its owner.** A warlock does not cast Spell Lock; his
  felhunter does, so the spend arrives with a `Pet-*` source. Ownership comes from the
  advanced block's `ownerGUID` (one pet cast line is enough — no summon needed) and
  from `SPELL_SUMMON`, and the footer marks it `(pet)`. Before this, the Voidscar +13
  report read `Dipndøtz 24 up / 0 on cd` for a key in which his demon spent Spell Lock
  three times. In the panel the pet's rows fold into the warlock's; mid-pull, where
  summing a secret amount is illegal, the row instead reads `Dipndøtz (pet)`.
- A warlock whose demon we **watched die** has no interrupt at all until he resummons.
  Never seeing a summon is not evidence of no pet — a log that opens with the demon
  already out never shows one.

## Keeping the data current

Nothing is hand-maintained. The cooldown and crowd-control tables are generated
from pinned [wago.tools](https://wago.tools) DB2 exports, and the per-dungeon
interruptible list from Mythic Dungeon Tools:

```sh
node tools/gen-interrupt-data.mjs --report        # base cooldowns + talent gate
node tools/gen-cc-data.mjs                        # blocking-aura table
node tools/gen-dungeon-interruptible.mjs --check  # which enemy casts can be kicked
```

### Which enemy casts can be interrupted

There are two lists and they rank:

1. `Data/Interruptible.lua` — **proof**. A `SPELL_INTERRUPT` in one of your own
   logs was seen stopping the spell. A hand-written `[id] = false` here asserts a
   cast is immune and beats everything.
2. `Data/DungeonInterruptible.lua` — **bootstrap**, 126 casts across 16 dungeons,
   generated from [Mythic Dungeon Tools](https://github.com/Nnoggie/MythicDungeonTools)
   (`Midnight/`), which curates it per dungeon enemy. Loaded second, never
   written back.

The bootstrap exists because proof only covers dungeons you have already run, and
Ruby Life Pools shared **zero** spell ids with the three dungeons parsed before
it. `--check` cross-checks the two: 30 of 30 ids our logs proved are in MDT's
list as well.

Blizzard's own DB2 cannot answer this. `SpellInterrupts.InterruptFlags` sets
`ON_INTERRUPT_CAST` on 53,444 of 122,119 spells — including your own Fireball,
and 31 of the 34 NPC casts in a Ruby Life Pools log where only 9 were ever
stopped. The flag says what kind of interruption applies to a cast *template*;
whether a given creature's cast is immune is set by the encounter script and is
not in any DB2 we can read.

MDT is GPL-2.0 and Unkicked is MIT. The generator reproduces spell ids only and
names MDT as the source in the output; `--no-bootstrap` runs the parser on proof
alone if you would rather not ship a derived file.

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

On a 12.x client the panel shows the `C_DamageMeter` view — interrupts pressed per
player, deaths, damage taken — for the live segment, any harvested pull, or the
whole key, chosen from a dropdown on the panel heading. `/uk why`
prints exactly which parts of the old design the client still refuses.

| | |
|---|---|
| `/uk why` | which events are blocked, what the meter does and does not give |
| `/uk kicks` | interrupts pressed per player, this pull and this key |
| `/uk current` / `/uk overall` | panel shows the live segment, or the whole key |
| `/uk segments` | list every segment the panel can show |
| `/uk sort <col> [asc\|desc]` | sort the panel — or just click the column heading |
| `/uk pull <n>` | panel shows pull *n* |
| `/uk history` | keys kept from earlier logins; `/uk history <n>` shows one |
| `/uk forget` | clear stored keys or harvested pulls — asks which, see above |
| `/uk pulls` | toggle the one-line chat report after each pull |
| `/uk` | toggle the panel |
| `/uk clear` | drop the current list |
| `/uk model` | what the addon believes about each party interrupt right now |
| `/uk data` | which build the generated tables came from |
| `/uk immune` | show casts that were immune to interrupts too |
| `/uk min <n>` | hide casts under *n* damage |
| `/uk lock` | stop the panel being dragged |
| `/uk reset` | put the panel back in the middle of the screen and show it |

The panel has three modes and says which one it is in, so "nothing on screen" is
never ambiguous:

* **meter** — the normal case on 12.x. One row per player: kicks, deaths, damage
  taken. The header names the segment and clicking it toggles pull ↔ key. The
  footer always reads *kicks pressed — missed casts: parse the log*, because the
  live view genuinely cannot answer the second question.
* **blind** — no feed *and* no meter. Two honest lines rather than empty rows.
* **feed** — one row per unkicked cast. Unreachable on a live 12.x client; it is
  the same code path the offline parser drives.

In combat the numbers on screen are *secret values*: the addon hands them to the
widget without ever reading them, which is why nothing is shortened to `k`/`m`
mid-pull and why totals only appear once the pull ends. If you cannot see the panel
at all, `/uk reset` recentres it.

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
