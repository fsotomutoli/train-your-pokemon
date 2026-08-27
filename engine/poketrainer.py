#!/usr/bin/env python3
"""Train Your Pokemon engine.

Reads Claude Code transcripts, converts work tokens into XP, and maintains the
active Pokemon plus the Pokedex in ~/.claude/pokemon-state.json.

Usage:
    poketrainer.py scan          # incremental update (normal use)
    poketrainer.py backfill      # re-read the whole history from scratch
    poketrainer.py status        # print state as JSON
    poketrainer.py choose <id>   # switch the active Pokemon
    poketrainer.py party <id>    # add a species to the team and train it
    poketrainer.py switch <id>   # rotate to another member of the team
    poketrainer.py withdraw <id> # take one out of storage and train it again
    poketrainer.py deposit <id>  # put a team member in the PC to free a slot
    poketrainer.py dex           # rebuild the Pokedex registry and its sprites
"""

import json
import os
import random
import re
import subprocess
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

CLAUDE_DIR = Path.home() / ".claude"
PROJECTS_DIR = CLAUDE_DIR / "projects"
STATE_PATH = CLAUDE_DIR / "pokemon-state.json"
STATUSLINE_PATH = CLAUDE_DIR / "pokemon-statusline"
# The Pokedex grid is 649 entries and the panel only reads it when opened, so it
# lives outside the state file that every scan rewrites and the menu bar reloads
# every 30 seconds.
DEX_PATH = CLAUDE_DIR / "pokemon-dex.json"

ASSETS_DIR = Path(__file__).resolve().parent.parent / "assets"
CACHE_DIR = ASSETS_DIR / "cache"
SPRITES_DIR = ASSETS_DIR / "sprites"

# 50 work tokens = 1 XP. Calibrated against the deduplicated rate of ~1.9M work
# tokens per active day, which puts a Pokemon at level 100 every ~26 active days
# (roughly 8 calendar weeks at a pace of working every other day).
#
# An earlier value of 100 was derived from the pre-deduplication numbers and was
# therefore 2.46x too slow, stretching a single Pokemon to ~15 weeks.
TOKENS_PER_XP = 50

# Level assigned to evolutions that PokeAPI reports without one — stones, trade
# and friendship all come back as min_level: null, so without this Eevee,
# Pikachu and Kadabra would never evolve at all.
#
# Chains with several such hops (Pichu -> Pikachu -> Raichu) cannot all land on
# the same level, so they are spread evenly and the last one lands here: one hop
# gives 40, two give 20 and 40.
FIXED_EVO_LEVEL = 40

MAX_LEVEL = 100

# Lowest level a Pokemon may be retired at.
#
# The XP curve is cubic, so half the total is spent between level 80 and 100 and
# a Pokedex gated on 100 grows about nine entries a year — a pace that reads as
# an achievement rather than a collection. Retiring early hands that pace to the
# trainer instead, but with no floor the whole roster could be retired at level 1
# in an afternoon, which is the clutter problem all over again.
#
# 40 is where a Pokemon is actually finished: sampling 120 chains, 98% have
# fully evolved by then and the median last evolution is level 34.5. An earlier
# floor of 50 sat ten levels past the point where anything still happens, so it
# only bought grind. At roughly one active day per entry it also keeps the
# collection reachable — 328 species is a decade at level 60, a couple of years
# here.
MIN_RETIRE_LEVEL = 40

# Slots on the team, counting the Pokemon currently being trained. Only that one
# earns XP; the rest sit on the bench frozen at the level they were parked at, so
# a chain can be put down when it gets boring and picked back up unchanged.
#
# Six is the party size the games use, and a limit is what keeps the team from
# turning into storage: with the sixth slot full, adding another means retiring
# someone first, which is gated on level 40. Unlimited slots would let a dozen
# Pokemon sit at level 5 forever and the Pokedex would never grow.
PARTY_SIZE = 6

# Odds of a new Pokemon being shiny, as one in N. Rolled once when a species
# starts being trained or is claimed, never on evolution: shininess is inherited,
# so a shiny Charmander yields a shiny Charizard.
#
# The games use 1/8192, which at this cadence means never.
#
# Calibrated against retiring at the floor, which is where most retirements will
# land since that is where a Pokemon has finished evolving: about 183 encounters
# a year, so one in 45 gives roughly four. Retiring later means fewer encounters
# and fewer shinies, which is the intended trade rather than a flaw — hunting
# them costs Pokedex quality.
SHINY_CHANCE = 45

# Ceiling for XP granted by a backfill. Replaying a long history otherwise hands
# the very first Pokemon a nearly free run to 100, which makes every later one
# feel like a wall.
BACKFILL_MAX_LEVEL = 60

# Commits grant XP, not Pokemon. They happen ~9 times a day, so handing out a
# Pokemon per commit would bury the Pokedex under level-1 entries nobody trained
# and drown the ones actually raised to 100. Feeding the training loop instead
# keeps a single route into the Pokedex.
#
# A commit is an outcome rather than consumption, so this also dilutes the
# incentive to burn tokens for their own sake: at the calibrated rates roughly a
# third of XP ends up coming from work rather than spend.
COMMIT_XP = 2000

# Starting a brand new project does grant a Pokemon, because it happens a
# handful of times a year — rare enough to stay meaningful and never clutter.
# It is recorded with its own source so the Pokedex still shows what was trained
# versus what was awarded.
PROJECT_GRANTS_POKEMON = True

# Duplicates of the same message.id are consecutive content blocks of one
# request, so a short window is enough to deduplicate across scans.
MSG_ID_WINDOW = 500

POKEAPI = "https://pokeapi.co/api/v2"
SPRITE_BASE = "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon"

# Legacy symbols in the U+2xxx range (star, high voltage, snowflake, skull,
# gear) can render as monochrome text glyphs, so they carry an explicit U+FE0F
# variation selector to force emoji presentation. Codepoints in the U+1Fxxx
# range are emoji-only and need no selector.
TYPE_EMOJI = {
    "normal": "⭐️", "fire": "🔥", "water": "💧", "electric": "⚡️", "grass": "🌿",
    "ice": "❄️", "fighting": "🥊", "poison": "☠️", "ground": "🏜️", "flying": "🌪️",
    "psychic": "🔮", "bug": "🐛", "rock": "🪨", "ghost": "👻", "dragon": "🐉",
    "dark": "🌑", "steel": "⚙️", "fairy": "🧚",
}


# --------------------------------------------------------------------------
# State
# --------------------------------------------------------------------------

def empty_state():
    return {
        "version": 1,
        "active": None,
        "bench": [],
        # Species ever owned, keyed by id. The Pokedex registers on acquisition
        # and never shrinks, which is what separates it from the PC: one records
        # that you had a species, the other holds the Pokemon itself.
        "dex": {},
        # Stored Pokemon. The key is the original name and stays for
        # compatibility with existing state files, but this is storage rather
        # than a registry — entries come back out — and the panel calls it
        # Bill's PC.
        "pokedex": [],
        "totals": {"xp_all_time": 0, "work_tokens": 0},
        "daily": {},
        "cursors": {},
        "recent_msg_ids": [],
        "events": [],
    }


def load_state():
    if not STATE_PATH.exists():
        return empty_state()
    try:
        with open(STATE_PATH) as fh:
            return json.load(fh)
    except (json.JSONDecodeError, OSError):
        return empty_state()


def save_state(state):
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_PATH.with_suffix(".json.tmp")
    with open(tmp, "w") as fh:
        json.dump(state, fh, indent=2, ensure_ascii=False)
    os.replace(tmp, STATE_PATH)


# --------------------------------------------------------------------------
# PokeAPI (cached on disk: the API asks callers not to hammer it)
# --------------------------------------------------------------------------

def _get_json(url, cache_name):
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    target = CACHE_DIR / f"{cache_name}.json"
    if target.exists():
        with open(target) as fh:
            return json.load(fh)
    req = urllib.request.Request(url, headers={"User-Agent": "train-your-pokemon/1.0"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.load(resp)
    with open(target, "w") as fh:
        json.dump(data, fh)
    return data


def xp_curve(growth_rate):
    """Return {level: cumulative_xp} for a growth rate."""
    data = _get_json(f"{POKEAPI}/growth-rate/{growth_rate}", f"growth-{growth_rate}")
    return {int(x["level"]): int(x["experience"]) for x in data["levels"]}


def get_species(species_id):
    return _get_json(f"{POKEAPI}/pokemon-species/{species_id}", f"species-{species_id}")


def get_pokemon(species_id):
    """The /pokemon endpoint (types and sprites); distinct from /pokemon-species."""
    return _get_json(f"{POKEAPI}/pokemon/{species_id}", f"pokemon-{species_id}")


def get_evolution_chain(chain_id):
    return _get_json(f"{POKEAPI}/evolution-chain/{chain_id}", f"chain-{chain_id}")


def _id_from_url(url):
    return int(url.rstrip("/").split("/")[-1])


def evolution_line(species_id):
    """Flatten the evolution chain into stages, each with its level and options.

    A stage keeps every branch it offers, so a chain like Eevee's presents all
    eight forms and the trainer picks one. Stages with a single option evolve on
    their own.

    Note: for a branching chain only the first branch's continuation is walked.
    Every branching gen-1 chain ends at the branch, so nothing is lost today.
    """
    species = get_species(species_id)
    chain_id = _id_from_url(species["evolution_chain"]["url"])
    chain = get_evolution_chain(chain_id)["chain"]

    hops = []
    node = chain
    while node["evolves_to"]:
        options = node["evolves_to"]
        details = options[0]["evolution_details"][0] if options[0]["evolution_details"] else {}
        hops.append({
            "raw_level": details.get("min_level"),
            "options": [{"species_id": _id_from_url(o["species"]["url"]),
                         "name": o["species"]["name"]} for o in options],
        })
        node = options[0]

    # Hops PokeAPI gives no level for are spread evenly, ending at the fixed
    # level: Kadabra -> Alakazam (trade) becomes 40, while Pichu's two levelless
    # hops become 20 and 40.
    levelless = [i for i, hop in enumerate(hops) if hop["raw_level"] is None]
    for position, index in enumerate(levelless, start=1):
        hops[index]["raw_level"] = round(FIXED_EVO_LEVEL * position / len(levelless))

    # Levels must strictly increase, or a synthetic level could land on or below
    # a real one earlier in the chain and make a stage unreachable.
    previous = 0
    for hop in hops:
        hop["min_level"] = max(hop["raw_level"], previous + 1)
        previous = hop["min_level"]

    stages = [{"species_id": _id_from_url(chain["species"]["url"]),
               "name": chain["species"]["name"],
               "min_level": None,
               "options": []}]
    for hop in hops:
        stages.append({
            # The first option is only a placeholder label for the stage; a
            # multi-option stage never evolves without an explicit choice.
            "species_id": hop["options"][0]["species_id"],
            "name": hop["options"][0]["name"],
            "min_level": hop["min_level"],
            "options": hop["options"],
        })
    return stages


def ensure_sprites(species_id, kinds=("animated", "artwork"), shiny=False):
    """Download the requested sprites once. Returns paths.

    `kinds` exists so bulk callers can skip the official artwork: it is ~150KB
    per species against ~20KB for the animated sprite, and the candidate grid
    only ever renders the small one.

    Shiny variants live under a `shiny/` segment and are cached separately, so a
    shiny Pokemon never overwrites the ordinary sprite of the same species.
    """
    SPRITES_DIR.mkdir(parents=True, exist_ok=True)
    variant = "shiny/" if shiny else ""
    suffix = "-shiny" if shiny else ""
    paths = {}
    for key, url, ext in (
        ("animated", f"{SPRITE_BASE}/versions/generation-v/black-white/animated/{variant}{species_id}.gif", "gif"),
        ("artwork", f"{SPRITE_BASE}/other/official-artwork/{variant}{species_id}.png", "png"),
    ):
        if key not in kinds:
            continue
        target = SPRITES_DIR / f"{species_id}-{key}{suffix}.{ext}"
        if not target.exists():
            try:
                req = urllib.request.Request(url, headers={"User-Agent": "train-your-pokemon/1.0"})
                with urllib.request.urlopen(req, timeout=15) as resp:
                    target.write_bytes(resp.read())
            except Exception:
                continue  # a missing sprite must not break the engine
        if target.exists():
            paths[key] = str(target)
    return paths


CRIES_DIR = ASSETS_DIR / "cries"

# PokeAPI ships two cry sets. "legacy" are the classic 8-bit cries from the
# original games, which is what most people recognise; "latest" are the
# re-recorded ones from the Sword/Shield era and sound noticeably different.
CRY_VERSION = "legacy"


def ensure_cry(species_id, version=CRY_VERSION):
    """Download the Pokemon's cry once. Returns the path, or None.

    PokeAPI serves cries as Ogg Vorbis. macOS CoreAudio decodes that natively
    (afinfo reports type 'Oggf', codec 'vorb'), so afplay works with no
    conversion step and no extra dependency.
    """
    CRIES_DIR.mkdir(parents=True, exist_ok=True)
    target = CRIES_DIR / f"{species_id}-{version}.ogg"
    if target.exists():
        return str(target)
    try:
        url = get_pokemon(species_id)["cries"][version]
        req = urllib.request.Request(url, headers={"User-Agent": "train-your-pokemon/1.0"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            target.write_bytes(resp.read())
        return str(target)
    except Exception:
        return None  # a missing cry must never break progression


def notify(title, subtitle, message, species_id=None):
    """Post a macOS notification and play the Pokemon's cry.

    osascript is used rather than UNUserNotificationCenter because this app is
    ad-hoc signed and has no notification entitlement. The cry is played
    detached so a 1.5s sound never delays a scan.
    """
    script = (f'display notification {json.dumps(message)} '
              f'with title {json.dumps(title)} '
              f'subtitle {json.dumps(subtitle)}')
    try:
        subprocess.run(["osascript", "-e", script], timeout=10,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass

    if species_id is not None:
        cry = ensure_cry(species_id)
        if cry:
            try:
                subprocess.Popen(["afplay", cry],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception:
                pass


def announce(state, events):
    """Turn progression events into notifications, without ever repeating one."""
    seen = state.setdefault("notified", {})
    for event in events:
        if event["type"] == "pre_evolution":
            key = f"pre-evo-{event['to']}-{event['at_level']}"
            if key in seen:
                continue
            seen[key] = event["at"]
            notify("Train Your Pokemon",
                   f"{event['from'].capitalize()} Lv.{event['at_level']}",
                   f"Está a punto de evolucionar a {event['to'].capitalize()} "
                   f"en el nivel {event['level']}.")

        elif event["type"] == "evolution":
            key = f"evo-{event['to']}"
            if key in seen:
                continue
            seen[key] = event["at"]
            notify("¡Evolución!",
                   f"{event['from'].capitalize()} → {event['to'].capitalize()}",
                   f"Tu {event['from'].capitalize()} evolucionó a "
                   f"{event['to'].capitalize()}.",
                   species_id=event.get("species_id"))

        elif event["type"] == "caught":
            key = f"caught-{event['who']}"
            if key in seen:
                continue
            seen[key] = event["at"]
            notify("¡Nivel 100!",
                   event["who"].capitalize(),
                   f"{event['who'].capitalize()} llegó al máximo y entró a tu "
                   f"Pokédex. Ya puedes entrenar a otro.",
                   species_id=event.get("species_id"))


def level_from_xp(xp, curve):
    level = 1
    for n in range(1, MAX_LEVEL + 1):
        if xp >= curve.get(n, float("inf")):
            level = n
        else:
            break
    return level


# --------------------------------------------------------------------------
# Incremental transcript reading
# --------------------------------------------------------------------------

# `git commit` only counts where a command actually starts: at the beginning of
# the string, after a separator, or inside a substitution. Matching the bare
# substring also caught commands that merely mention it — a shell `case` pattern
# or an echo — which inflated the count by a quarter.
COMMIT_PATTERN = re.compile(r"(?:^|[;&|]\s*|\$\(\s*|`\s*|\n\s*)git\s+commit\b")


def _commits_in(message):
    """Count git commits among a message's Bash tool calls.

    Commits are read from the transcript itself rather than from git, so no repo
    needs a hook installed and every project counts automatically.
    """
    content = message.get("content")
    if not isinstance(content, list):
        return 0
    total = 0
    for block in content:
        if not isinstance(block, dict) or block.get("type") != "tool_use":
            continue
        if block.get("name") != "Bash":
            continue
        command = (block.get("input") or {}).get("command", "")
        total += len(COMMIT_PATTERN.findall(command))
    return total


def collect_tokens(state, from_scratch=False):
    """Scan the .jsonl transcripts and return {date: work_tokens} for new data.

    Also counts new commits and newly seen projects, which award XP of their own.
    """
    if from_scratch:
        state["cursors"] = {}
        state["recent_msg_ids"] = []

    cursors = state["cursors"]
    seen = set(state.get("recent_msg_ids", []))
    seen_order = list(state.get("recent_msg_ids", []))
    per_day = {}

    known_projects = set(state.setdefault("projects_seen", []))
    counts = {"commits": 0, "new_projects": 0}
    state["_last_counts"] = counts

    if not PROJECTS_DIR.exists():
        return per_day

    for path in sorted(PROJECTS_DIR.rglob("*.jsonl")):
        key = str(path)
        # One directory per project, so its name identifies the project without
        # having to parse cwd out of every entry.
        project = path.parent.name
        if project not in known_projects:
            known_projects.add(project)
            counts["new_projects"] += 1

        try:
            size = path.stat().st_size
        except OSError:
            continue

        cursor = cursors.get(key, {"offset": 0})
        offset = cursor.get("offset", 0)
        # File shrank: it was rotated or compacted, so re-read from the start.
        if offset > size:
            offset = 0
        if offset == size:
            continue

        try:
            fh = open(path, "r", errors="ignore")
        except OSError:
            continue

        with fh:
            fh.seek(offset)
            last_complete = offset
            for line in fh:
                # Partial line (Claude Code is still writing): stop here and
                # resume from the last complete newline on the next scan.
                if not line.endswith("\n"):
                    break
                last_complete += len(line.encode("utf-8"))
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue

                message = entry.get("message") or {}
                usage = message.get("usage")
                if not usage:
                    continue

                # Counted before the dedup below, and on every line. A message is
                # written one content block per line, all sharing one id: the
                # thinking block lands on the first line and the tool_use on the
                # second, so deduplicating by id first would skip every commit.
                # Tokens still need that dedup, since each line repeats them.
                counts["commits"] += _commits_in(message)

                msg_id = message.get("id")
                if not msg_id or msg_id in seen:
                    continue
                seen.add(msg_id)
                seen_order.append(msg_id)

                work = usage.get("output_tokens", 0) + usage.get("cache_creation_input_tokens", 0)
                if work <= 0:
                    continue
                date = (entry.get("timestamp") or "")[:10] or datetime.now(timezone.utc).strftime("%Y-%m-%d")
                per_day[date] = per_day.get(date, 0) + work

            cursors[key] = {"offset": last_complete}

    if len(seen_order) > MSG_ID_WINDOW:
        seen_order = seen_order[-MSG_ID_WINDOW:]
    state["recent_msg_ids"] = seen_order
    state["projects_seen"] = sorted(known_projects)
    return per_day


# --------------------------------------------------------------------------
# Progression
# --------------------------------------------------------------------------

def _snapshot(record):
    """Deep copy through JSON, so a stored record cannot be mutated later
    through a shared `line` or `choices` object."""
    return json.loads(json.dumps(record))


def entry_base(entry):
    """Base species of a stored entry's chain.

    Entries written before records existed have to be resolved through the API
    cache; newer ones carry it already.
    """
    record = entry.get("record") or {}
    if record.get("base_species_id"):
        return record["base_species_id"]
    try:
        return evolution_line(entry["species_id"])[0]["species_id"]
    except Exception:
        return entry["species_id"]


def file_in_pc(state, member, source):
    """Put a Pokemon in the PC, keeping one entry per chain.

    Matched on the chain rather than the current form, because a Pokemon is
    filed the moment it reaches level 100 and evolution waits for the trainer to
    watch it: a Charmander filed at 100 and evolved afterwards would come back
    as a second entry under Charizard. An existing entry is replaced instead, so
    the PC shows the furthest form and level the chain ever reached.
    """
    entry = {
        "species_id": member["species_id"],
        "name": member["name"],
        "level": member["level"],
        "source": source,
        "maxed": member["level"] >= MAX_LEVEL,
        "shiny": bool(member.get("shiny")),
        "completed_at": datetime.now(timezone.utc).isoformat(),
        # Kept whole so taking it back out restores it exactly, rather than
        # rebuilding an approximation from level and species.
        "record": _snapshot(member),
    }
    base = member.get("base_species_id") or entry_base(entry)
    for index, existing in enumerate(state["pokedex"]):
        if entry_base(existing) == base:
            state["pokedex"][index] = entry
            return entry
    state["pokedex"].append(entry)
    return entry


def record_from_entry(entry):
    """Rebuild a trainable record from a stored entry.

    Entries filed before Pokemon could be taken back out carry only species,
    level and badge, so everything else is derived: the chain from the species,
    the XP from what that level is worth on its curve, and the branch it took
    from the form it was stored as.

    The derived XP is exactly the level's threshold rather than anything above
    it. Progress towards the next level was never recorded, and inventing some
    would be worse than starting the level clean.
    """
    stored = entry.get("record")
    if stored:
        return _snapshot(stored)

    species_id = entry["species_id"]
    line = evolution_line(species_id)
    growth_rate = get_species(species_id)["growth_rate"]["name"]
    curve = xp_curve(growth_rate)
    level = max(1, min(int(entry.get("level", 1)), MAX_LEVEL))

    record = {
        "species_id": species_id,
        "name": entry["name"],
        "base_species_id": line[0]["species_id"],
        "growth_rate": growth_rate,
        "xp": curve.get(level, 0),
        "level": level,
        "shiny": bool(entry.get("shiny")),
        "line": line,
        "started_at": entry.get("completed_at") or datetime.now(timezone.utc).isoformat(),
    }

    # The branch it took, so a forked chain comes back on the same fork instead
    # of being offered the choice a second time.
    choices = {index: species_id
               for index, stage in enumerate(line)
               if index and any(o["species_id"] == species_id for o in stage["options"])}
    if choices:
        record["choices"] = {str(k): v for k, v in choices.items()}

    # Already maxed: keep the mark, or apply_xp would file it straight back into
    # storage and undo the withdrawal on the spot.
    if level >= MAX_LEVEL:
        record["completed_at"] = entry.get("completed_at")

    return record


def register_species(state, species_id, name, shiny=False):
    """Record a species in the Pokedex. Idempotent.

    The first sighting keeps its date, but shininess is sticky: having owned a
    shiny one is worth remembering even if the one you hold now is not.
    """
    dex = state.setdefault("dex", {})
    key = str(species_id)
    entry = dex.get(key)
    if entry is None:
        dex[key] = {
            "name": name,
            "first_seen": datetime.now(timezone.utc).isoformat(),
            "shiny": bool(shiny),
        }
    else:
        entry["name"] = name
        entry["shiny"] = bool(entry.get("shiny")) or bool(shiny)
    return dex[key]


def forms_taken(member):
    """Every form a Pokemon has actually been, base first.

    A chain is only walked as far as the Pokemon got, and at a branching stage
    only the option it took counts — picking Umbreon never means having owned a
    Vaporeon.
    """
    line = member.get("line") or []
    choices = member.get("choices") or {}
    current = member.get("species_id")
    forms = []

    for index, stage in enumerate(line):
        if index == 0:
            forms.append((stage["species_id"], stage["name"]))
            if stage["species_id"] == current:
                break
            continue

        options = stage.get("options") or []
        picked = next((o for o in options if o["species_id"] == current), None)
        if picked is None:
            chosen_id = choices.get(str(index))
            if chosen_id is None and len(options) == 1:
                picked = options[0]
            else:
                picked = next((o for o in options if o["species_id"] == chosen_id), None)
        if picked is None:
            # A stage it never reached, or a branch with no record of the pick.
            break
        forms.append((picked["species_id"], picked["name"]))
        if picked["species_id"] == current:
            break

    return forms


def reconstruct_dex(state):
    """Seed the registry from what the trainer holds right now.

    Only current holdings are walked, which is the honest bound: a Pokemon that
    was trained and is no longer anywhere left no record to recover. Everything
    still on the team or in the PC contributes every form it passed through.
    """
    members = ([state["active"]] if state.get("active") else []) + bench(state)
    for member in members:
        shiny = bool(member.get("shiny"))
        for species_id, name in forms_taken(member):
            register_species(state, species_id, name, shiny)

    for entry in state.get("pokedex", []):
        record = entry.get("record")
        shiny = bool(entry.get("shiny"))
        if record:
            for species_id, name in forms_taken(record):
                register_species(state, species_id, name, shiny)
        else:
            # No record to walk: at least the form it was filed as is certain.
            register_species(state, entry["species_id"], entry["name"], shiny)


def bench(state):
    """Team members that are not the one currently earning XP.

    Kept beside `active` rather than folding the active Pokemon into a list with
    an index, because every frontend and half the engine reads `state["active"]`
    directly; a bench is additive and states written before the team existed
    still load.
    """
    return state.setdefault("bench", [])


def party_slots_used(state):
    return len(bench(state)) + (1 if state.get("active") else 0)


def training_bases(state):
    """Base species of every chain on the team, active and benched alike."""
    members = bench(state) + ([state["active"]] if state.get("active") else [])
    return {m["base_species_id"] for m in members if m.get("base_species_id")}


def ensure_active(state, species_id=None):
    if state.get("active") and species_id is None:
        return state["active"]

    requested = species_id or 25  # Pikachu by default
    species = get_species(requested)
    line = evolution_line(requested)
    # Training always starts at the base of the chain: asking for Pikachu means
    # raising it from Pichu, so level and displayed species never contradict.
    base = line[0]
    state["active"] = {
        "species_id": base["species_id"],
        "name": base["name"],
        "base_species_id": base["species_id"],
        "growth_rate": species["growth_rate"]["name"],
        "xp": 0,
        "level": 1,
        # Rolled once, here. Shininess is inherited through the chain, so it is
        # never re-rolled on evolution.
        "shiny": random.randrange(SHINY_CHANCE) == 0,
        "line": line,
        "started_at": datetime.now(timezone.utc).isoformat(),
    }
    register_species(state, base["species_id"], base["name"],
                     state["active"]["shiny"])
    return state["active"]


def _current_stage_index(active):
    """Which stage of its line the Pokemon is currently at.

    Matched against every option of a stage, not just its label, so a Pokemon
    that took a branch (Umbreon, not the first-listed Vaporeon) is still found.
    """
    for index, stage in enumerate(active["line"]):
        if index == 0:
            if stage["species_id"] == active["species_id"]:
                return 0
        elif any(o["species_id"] == active["species_id"] for o in stage["options"]):
            return index
    return 0


def apply_xp(state, gained_xp, cap_level=None):
    """Add XP to the active Pokemon, evolve it, and catch it at level 100.

    `cap_level` limits how far the XP may carry it, used by the backfill so
    replayed history cannot hand the first Pokemon a free run to 100.
    """
    active = ensure_active(state)
    curve = xp_curve(active["growth_rate"])
    events = []

    level_before = active["level"]
    ceiling = curve[cap_level] if cap_level else curve[MAX_LEVEL]
    active["xp"] = min(active["xp"] + gained_xp, ceiling)
    active["level"] = level_from_xp(active["xp"], curve)

    if active["level"] > level_before:
        # Distinct key names on purpose: `from`/`to` carry species names on
        # evolution events, and reusing them for integers here made the whole
        # event list fail to decode in the Swift app, blanking the menu bar.
        events.append({"type": "level_up",
                       "from_level": level_before, "to_level": active["level"],
                       "at": datetime.now(timezone.utc).isoformat()})

    # State written before branch support has stages without "options"; rebuild
    # the line rather than crashing on it.
    if any("options" not in stage for stage in active["line"]):
        active["line"] = evolution_line(active["base_species_id"])

    # Evolution never happens on its own, not even when a stage has a single
    # option. Reaching the level only marks it pending; the panel plays the
    # evolution animation and that is what commits it. Doing it here would mean
    # the trainer is told about a change they never got to watch.
    index = _current_stage_index(active)
    following = index + 1
    pending = None
    if following < len(active["line"]):
        stage = active["line"][following]
        if active["level"] >= stage["min_level"]:
            pending = {
                "stage": following,
                "level": stage["min_level"],
                "options": stage["options"],
            }
    active["pending_evolution"] = pending

    # Announced once per stage, so a scan every 30 seconds does not repeat it.
    if pending and active.get("announced_stage") != pending["stage"]:
        active["announced_stage"] = pending["stage"]
        events.append({"type": "ready_to_evolve",
                       "who": active["name"],
                       "level": pending["level"],
                       "choices": len(pending["options"]),
                       "at": datetime.now(timezone.utc).isoformat()})

    # Level 100: goes into the Pokedex and becomes swappable.
    if active["level"] >= MAX_LEVEL and not active.get("completed_at"):
        active["completed_at"] = datetime.now(timezone.utc).isoformat()
        file_in_pc(state, active, "trained")
        events.append({"type": "caught", "who": active["name"],
                       "species_id": active["species_id"],
                       "at": active["completed_at"]})

    state["events"] = (state.get("events", []) + events)[-50:]
    return events


def _with_option_sprites(pending):
    """Fetches sprites for a pending branch so the picker can render them.

    Eevee's branches reach well past gen 1 (Sylveon is 700), so these are not
    among the sprites already downloaded for the candidate grid.
    """
    if not pending:
        return None
    for option in pending["options"]:
        sprites = ensure_sprites(option["species_id"], kinds=("animated",))
        # Gen-5 animated sprites only cover species up to 649, so later branches
        # such as Sylveon (700) have none. Fall back to the official artwork.
        if not sprites.get("animated"):
            sprites = ensure_sprites(option["species_id"], kinds=("artwork",))
        option["sprites"] = sprites
    return pending


def _party_view(state):
    """The team as the panel renders it: the one being trained, then the bench.

    Nothing is recomputed for a benched Pokemon — its level and XP are read
    straight off the record it was parked with, which is exactly why putting one
    down costs nothing and picking it up returns it unchanged.
    """
    curves = {}

    def view(member, is_active):
        shiny = bool(member.get("shiny"))
        # Gen-5 animated sprites stop at 649, so a branch reached past it —
        # Sylveon is 700 — has none and would render as an empty box. Falling
        # back to the artwork also stops the missing file being re-requested on
        # every scan.
        sprites = ensure_sprites(member["species_id"], kinds=("animated",), shiny=shiny)
        if not sprites.get("animated"):
            sprites = ensure_sprites(member["species_id"], kinds=("artwork",), shiny=shiny)

        rate = member["growth_rate"]
        if rate not in curves:
            curves[rate] = xp_curve(rate)
        curve = curves[rate]
        at_level = curve.get(member["level"], 0)
        at_next = curve.get(member["level"] + 1)
        if at_next and at_next > at_level:
            pct = int(100 * (member["xp"] - at_level) / (at_next - at_level))
        else:
            pct = 100
        return {
            "species_id": member["species_id"],
            "name": member["name"],
            "level": member["level"],
            "pct": max(0, min(100, pct)),
            "shiny": shiny,
            "active": is_active,
            "sprites": sprites,
        }

    return [view(state["active"], True)] + [view(m, False) for m in bench(state)]


def update_display(state):
    """Precompute what the statusline and the menu bar app render.

    Done here (once per scan) rather than in each frontend, because the
    statusline redraws several times per second and cannot pay that cost.
    """
    active = state.get("active")
    if not active:
        return

    curve = xp_curve(active["growth_rate"])
    level = active["level"]
    xp = active["xp"]
    xp_at_level = curve.get(level, 0)
    xp_next = curve.get(level + 1)

    if xp_next and xp_next > xp_at_level:
        pct = int(100 * (xp - xp_at_level) / (xp_next - xp_at_level))
    else:
        pct = 100

    try:
        types = [t["type"]["name"] for t in get_pokemon(active["species_id"])["types"]]
    except Exception:
        types = []

    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    next_stage = next((s for s in active["line"]
                       if s["min_level"] and s["min_level"] > level), None)

    state["display"] = {
        "name": active["name"],
        "level": level,
        "xp": xp,
        "xp_next": xp_next,
        "pct": max(0, min(100, pct)),
        "types": types,
        "emoji": TYPE_EMOJI.get(types[0], "✨") if types else "✨",
        "today_xp": state["daily"].get(today, 0),
        # Deposited Pokemon are parked, not collected, so they are left out of
        # the count even though they sit in the same list.
        "caught": sum(1 for p in state["pokedex"] if p.get("source") != "stored"),
        "commits": state["totals"].get("commits", 0),
        # Rewards from new projects, waiting for a species to be picked.
        "unclaimed": state.get("unclaimed", 0),
        # The trainer sets the pace: retire early for a wider Pokedex, or push
        # to 100 for the badge.
        "can_retire": level >= MIN_RETIRE_LEVEL,
        "retire_level": MIN_RETIRE_LEVEL,
        "next_evo": next_stage["name"] if next_stage else None,
        "next_evo_level": next_stage["min_level"] if next_stage else None,
        # Set when the Pokemon has reached a branching stage and is waiting for
        # the trainer to pick a form. The panel renders the options.
        "pending_evolution": _with_option_sprites(active.get("pending_evolution")),
        "shiny": bool(active.get("shiny")),
        "sprites": ensure_sprites(active["species_id"], shiny=bool(active.get("shiny"))),
        # Cached here so the menu bar app can play it on open without paying
        # the cost of spawning Python.
        "cry": ensure_cry(active["species_id"]),
        # The whole team, so the panel renders the rotation without a second
        # read of the state file.
        "party": _party_view(state),
        "party_size": PARTY_SIZE,
        # The Pokedex counts species ever owned; `caught` counts what is stored.
        "dex_registered": len(state.get("dex", {})),
        "dex_total": MAX_SPECIES_ID,
    }

    # Flat line for the statusline, read with bash's `read` builtin so no
    # process is spawned. Spawning jq cost ~41ms per redraw; this costs ~0.
    display = state["display"]
    fields = [display["emoji"], display["name"].capitalize(),
              str(display["level"]), str(display["pct"])]
    tmp = STATUSLINE_PATH.with_suffix(".tmp")
    tmp.write_text("\t".join(fields) + "\n", encoding="utf-8")
    os.replace(tmp, STATUSLINE_PATH)


# Highest species id offered for training. 649 is the end of generation V, and
# it is exactly where the animated pixel sprites stop: from 650 on only the
# 475px official artwork exists, which looks out of place beside pixel art in
# the menu bar and the grid. PokeAPI itself goes to 1025.
MAX_SPECIES_ID = 649

CANDIDATES_PATH = CACHE_DIR / "candidates.json"


def base_forms():
    """Base-form species of generation 1, i.e. the starting point of each chain.

    Derived from evolution chains rather than by testing every species, because
    a chain names its base directly. The result is cached to a single file: the
    walk costs ~80 requests and only needs doing once.
    """
    if CANDIDATES_PATH.exists():
        with open(CANDIDATES_PATH) as fh:
            return json.load(fh)

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    listing = _get_json(f"{POKEAPI}/evolution-chain?limit=2000", "chain-list")

    def base_of(entry):
        try:
            chain = get_evolution_chain(_id_from_url(entry["url"]))["chain"]
        except Exception:
            return None
        species_id = _id_from_url(chain["species"]["url"])
        if species_id > MAX_SPECIES_ID:
            return None
        return {"species_id": species_id, "name": chain["species"]["name"]}

    # Hundreds of chains, one request each: serially this takes ~13 minutes.
    # Eight workers keeps it to a couple while staying polite to the API.
    with ThreadPoolExecutor(max_workers=8) as pool:
        forms = [f for f in pool.map(base_of, listing["results"]) if f]

    forms.sort(key=lambda f: f["species_id"])
    with open(CANDIDATES_PATH, "w") as fh:
        json.dump(forms, fh)
    return forms


def candidates(state):
    """Base forms the trainer has not completed yet, with sprites ready."""
    caught = {p["species_id"] for p in state.get("pokedex", [])}
    # A caught Pokemon is stored in its final form, so compare whole chains.
    caught_bases = set()
    for species_id in caught:
        try:
            caught_bases.add(evolution_line(species_id)[0]["species_id"])
        except Exception:
            continue

    # Chains already on the team are out too: the grid offers what can be
    # started, and one that is being trained — active or benched — cannot be
    # started a second time.
    on_team = training_bases(state)
    available = [f for f in base_forms()
                 if f["species_id"] not in caught_bases and f["species_id"] not in on_team]

    # Only the small sprite: the grid never shows the 475px artwork, and
    # fetching both is what made an early version crawl. Parallel for the same
    # reason as the chain walk — there are hundreds of these.
    def with_sprite(form):
        form["sprites"] = ensure_sprites(form["species_id"], kinds=("animated",))
        return form

    with ThreadPoolExecutor(max_workers=8) as pool:
        return list(pool.map(with_sprite, available))


def scan(from_scratch=False):
    state = load_state()
    if from_scratch:
        # A backfill recomputes XP from zero, but the species being raised, the
        # branch choices and the Pokedex are the trainer's, not derived data —
        # wiping them would silently swap their Pokemon back to the default.
        previous = state.get("active") or {}
        keep_species = previous.get("base_species_id")
        keep_choices = previous.get("choices", {})
        keep_pokedex = state.get("pokedex", [])
        keep_unclaimed = state.get("unclaimed", 0)
        # The bench holds Pokemon with XP already granted and the registry
        # records species that were genuinely owned — neither is derived from
        # the transcripts, so replaying them must not wipe either.
        keep_bench = state.get("bench", [])
        keep_dex = state.get("dex", {})

        state = empty_state()
        state["pokedex"] = keep_pokedex
        state["unclaimed"] = keep_unclaimed
        state["bench"] = keep_bench
        state["dex"] = keep_dex
        if keep_species:
            ensure_active(state, species_id=keep_species)
            state["active"]["choices"] = keep_choices

    per_day = collect_tokens(state, from_scratch=from_scratch)
    new_work = sum(per_day.values())
    counts = state.pop("_last_counts", {"commits": 0, "new_projects": 0})

    # A backfill replays the whole history, so its commits and projects are not
    # news: record them as the baseline instead of paying them out. Otherwise
    # the first scan would hand over years of rewards at once, the same problem
    # the level ceiling below exists to prevent.
    if from_scratch:
        state["totals"]["commits"] = counts["commits"]
        counts = {"commits": 0, "new_projects": 0}
    else:
        state["totals"]["commits"] = state["totals"].get("commits", 0) + counts["commits"]
        if PROJECT_GRANTS_POKEMON and counts["new_projects"]:
            state["unclaimed"] = state.get("unclaimed", 0) + counts["new_projects"]

    commit_xp = counts["commits"] * COMMIT_XP

    if new_work == 0 and commit_xp == 0:
        # Even with no new tokens the display must refresh: the day rolls over
        # (today_xp resets) and sprites may still be missing.
        ensure_active(state)
        reconstruct_dex(state)
        update_display(state)
        save_state(state)
        return state, []

    for date, tokens in per_day.items():
        state["daily"][date] = state["daily"].get(date, 0) + tokens // TOKENS_PER_XP

    gained_xp = new_work // TOKENS_PER_XP + commit_xp
    state["totals"]["work_tokens"] += new_work
    state["totals"]["xp_all_time"] += gained_xp

    events = apply_xp(state, gained_xp, cap_level=BACKFILL_MAX_LEVEL if from_scratch else None)
    # Cheap: walks the lines already stored on each member, no requests. Keeps
    # the registry seeded for state files written before it existed.
    reconstruct_dex(state)
    update_display(state)
    # Notifications are posted by the menu bar app, not here. Going through
    # osascript attributes them to Script Editor, which on this machine has its
    # banner style set to none: the cry played but no banner ever appeared.
    # The app posts them under its own bundle id via UNUserNotificationCenter,
    # deduplicating against a timestamp watermark over `events`.
    state["last_scan"] = datetime.now(timezone.utc).isoformat()
    save_state(state)
    return state, events


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "scan"

    if command == "scan":
        state, events = scan()
        for event in events:
            print(f"  {event['type']}: {event}")
        active = state.get("active")
        if active:
            print(f"{active['name']} Lv.{active['level']} ({active['xp']:,} XP)")

    elif command == "backfill":
        started = time.time()
        state, events = scan(from_scratch=True)
        active = state["active"]
        print(f"Backfill in {time.time() - started:.1f}s")
        print(f"  work tokens: {state['totals']['work_tokens']:,}")
        print(f"  total XP:    {state['totals']['xp_all_time']:,}")
        print(f"  active:      {active['name']} Lv.{active['level']}")
        print(f"  events:      {len(events)}")

    elif command == "status":
        print(json.dumps(load_state(), indent=2, ensure_ascii=False))

    elif command == "dex":
        # Rebuilds the registry and writes the grid the panel renders. Kept out
        # of `scan` because it fetches a sprite for every species in range: a
        # one-off cost, not something to pay every 30 seconds.
        state = load_state()
        reconstruct_dex(state)
        save_state(state)
        dex = state.get("dex", {})
        started = time.time()

        def dex_entry(species_id):
            entry = dex.get(str(species_id))
            shiny = bool(entry and entry.get("shiny"))
            sprites = ensure_sprites(species_id, kinds=("animated",), shiny=shiny)
            # A shiny sprite may be missing where the ordinary one is not.
            if shiny and not sprites.get("animated"):
                sprites = ensure_sprites(species_id, kinds=("animated",))
            return {
                "species_id": species_id,
                # Unregistered entries stay nameless on purpose: the games show
                # ????? until you have owned one, and it saves 600-odd lookups.
                "name": entry["name"] if entry else None,
                "registered": entry is not None,
                "shiny": shiny,
                "sprite": sprites.get("animated"),
            }

        with ThreadPoolExecutor(max_workers=8) as pool:
            entries = list(pool.map(dex_entry, range(1, MAX_SPECIES_ID + 1)))

        payload = {"total": MAX_SPECIES_ID,
                   "registered": sum(1 for e in entries if e["registered"]),
                   "entries": entries}
        tmp = DEX_PATH.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, DEX_PATH)
        missing = sum(1 for e in entries if not e["sprite"])
        print(f"{payload['registered']}/{payload['total']} registrados "
              f"en {time.time() - started:.1f}s"
              + (f" ({missing} sin sprite)" if missing else ""))

    elif command == "candidates":
        # Written to the state file so the menu bar app reads it the same way
        # it reads everything else, instead of parsing stdout.
        state = load_state()
        state["candidates"] = candidates(state)
        save_state(state)
        print(f"{len(state['candidates'])} available")

    elif command == "retire":
        # Retires the active Pokemon into the Pokedex at whatever level it
        # reached and starts the next one, in a single step. Doing both at once
        # avoids ever having no active Pokemon, which the panel has no state for.
        state = load_state()
        active = state.get("active")
        if not active:
            print("Nothing to retire.")
            return 1
        if active["level"] < MIN_RETIRE_LEVEL:
            print(f"{active['name'].capitalize()} is level {active['level']}. "
                  f"Retiring needs level {MIN_RETIRE_LEVEL}.")
            return 1
        # Retiring frees a slot and whoever is next on the bench takes over, so
        # naming the species to train next is only needed with an empty bench.
        if len(sys.argv) < 3 and not bench(state):
            print("Name the species to train next: retire <species_id>")
            return 1

        # The successor gets the same guards as `party`, which the panel applies
        # by filtering the grid but the command has to check for itself. Without
        # this the chain being retired could be started again in the same breath
        # and end up in the PC and on the team at once.
        if len(sys.argv) >= 3:
            successor = evolution_line(int(sys.argv[2]))[0]
            if successor["species_id"] in training_bases(state):
                print(f"{successor['name'].capitalize()} is already on the team.")
                return 1
            if any(entry_base(p) == successor["species_id"] for p in state["pokedex"]):
                print(f"{successor['name'].capitalize()}'s chain is in the PC. "
                      f"Bring it back out with: withdraw <species_id>")
                return 1

        # Reaching 100 already filed it, in which case this replaces that entry
        # rather than adding a second one for the same chain.
        file_in_pc(state, active, "trained")
        retired = f"{active['name']} Lv.{active['level']}"

        if len(sys.argv) >= 3:
            ensure_active(state, species_id=int(sys.argv[2]))
        else:
            state["active"] = bench(state).pop(0)
        update_display(state)
        save_state(state)
        print(f"Retired {retired}. Now training {state['active']['name']}.")

    elif command == "party":
        # Adds a species to the team and starts training it right away. The one
        # being trained is benched, not discarded: it keeps its XP, its level and
        # the branches it already took, and comes back exactly as it was left.
        state = load_state()
        if len(sys.argv) < 3:
            members = ", ".join(f"{m['name']} Lv.{m['level']}"
                                for m in ([state["active"]] if state.get("active") else [])
                                + bench(state))
            print(f"Team ({party_slots_used(state)}/{PARTY_SIZE}): {members or 'empty'}")
            print("Name the species to add: party <species_id>")
            return 1

        if party_slots_used(state) >= PARTY_SIZE:
            print(f"The team is full ({PARTY_SIZE}). Retire one to make room.")
            return 1

        # Training always starts at the base of the chain, so membership is
        # compared there too: asking for Pikachu when Pichu is already benched
        # is the same chain twice.
        base = evolution_line(int(sys.argv[2]))[0]
        if base["species_id"] in training_bases(state):
            print(f"{base['name'].capitalize()} is already on the team.")
            return 1
        caught_bases = set()
        for entry in state.get("pokedex", []):
            try:
                caught_bases.add(evolution_line(entry["species_id"])[0]["species_id"])
            except Exception:
                continue
        if base["species_id"] in caught_bases:
            print(f"{base['name'].capitalize()}'s chain is in storage. "
                  f"Bring it back out with: withdraw <species_id>")
            return 1

        if state.get("active"):
            bench(state).append(state["active"])
        ensure_active(state, species_id=base["species_id"])
        update_display(state)
        save_state(state)
        new = state["active"]
        print(f"Added {new['name']} to the team "
              f"({party_slots_used(state)}/{PARTY_SIZE}). Now training it.")

    elif command == "switch":
        # Rotates the team: the Pokemon being trained goes to the back of the
        # bench and the one named takes over. No XP moves and nothing is filed,
        # which is the whole point — this is putting one down, not finishing it.
        state = load_state()
        benched = bench(state)
        if len(sys.argv) < 3 or not benched:
            if not benched:
                print("Nothing on the bench. Add one with: party <species_id>")
            else:
                names = ", ".join(f"{m['name']} Lv.{m['level']} ({m['species_id']})"
                                  for m in benched)
                print(f"Name who takes over: switch <species_id>. On the bench: {names}")
            return 1

        wanted = int(sys.argv[2])
        # Matched on either id: the panel sends the current form, while a person
        # typing the command is likelier to reach for the chain they picked.
        index = next((i for i, m in enumerate(benched)
                      if wanted in (m["species_id"], m.get("base_species_id"))), None)
        if index is None:
            names = ", ".join(f"{m['name']} ({m['species_id']})" for m in benched)
            print(f"{wanted} is not on the bench. Choose from: {names}")
            return 1

        incoming = benched.pop(index)
        outgoing = state.get("active")
        if outgoing:
            benched.append(outgoing)
        state["active"] = incoming
        update_display(state)
        save_state(state)
        if outgoing:
            print(f"Benched {outgoing['name']} Lv.{outgoing['level']}. "
                  f"Now training {incoming['name']} Lv.{incoming['level']}.")
        else:
            print(f"Now training {incoming['name']} Lv.{incoming['level']}.")

    elif command == "withdraw":
        # Takes a stored Pokemon back out and resumes training it where it left
        # off. Storage is a PC, not a registry: the entry leaves it while the
        # Pokemon is on the team and returns on the next retirement, at whatever
        # level it reached by then. One entry per chain still holds, so nothing
        # can be duplicated by cycling a Pokemon in and out.
        state = load_state()
        stored = state.get("pokedex", [])
        if len(sys.argv) < 3:
            names = ", ".join(f"{p['name']} Lv.{p['level']} ({p['species_id']})"
                              for p in stored)
            print(f"Name who comes out: withdraw <species_id>. In storage: {names or 'nothing'}")
            return 1

        wanted = int(sys.argv[2])
        # Either form identifies it, as with `switch` and `deposit`. The panel
        # passes the entry's own species, but an entry filed at level 100 keeps
        # the form it was filed as until it is filed again, so the chain has to
        # match too.
        index = next((i for i, p in enumerate(stored)
                      if wanted in (p["species_id"], entry_base(p))), None)
        if index is None:
            print(f"{wanted} is not in the PC.")
            return 1

        if party_slots_used(state) >= PARTY_SIZE:
            print(f"The team is full ({PARTY_SIZE}). Retire one to make room.")
            return 1

        record = record_from_entry(stored[index])
        # Remembered so putting it back does not demote what it had already
        # earned: a Lv.100 badge or a project award would otherwise come back as
        # a plain deposit and drop out of the caught count for good.
        record["filed_source"] = stored[index].get("source", "trained")
        # A Pokemon that reached 100 is filed while still being trained, so it
        # can be in storage and on the team at once. Withdrawing it then would
        # clone it.
        if record["base_species_id"] in training_bases(state):
            print(f"{record['name'].capitalize()} is already on the team.")
            return 1

        stored.pop(index)
        if state.get("active"):
            bench(state).append(state["active"])
        state["active"] = record
        for species_id, name in forms_taken(record):
            register_species(state, species_id, name, bool(record.get("shiny")))
        # Recomputes the level from the restored XP and re-checks whether the
        # form it comes back as already qualifies for the next stage.
        apply_xp(state, 0)
        update_display(state)
        save_state(state)
        print(f"{record['name'].capitalize()} Lv.{record['level']} is out of storage "
              f"and training ({party_slots_used(state)}/{PARTY_SIZE}).")

    elif command == "deposit":
        # Puts a team member in the PC to free a slot, at whatever level it is.
        #
        # MIN_RETIRE_LEVEL is deliberately not checked here. The floor exists so
        # that a collection entry means something, and depositing does not make
        # one: the entry is marked `stored` rather than `trained` and is left out
        # of the caught count. Without this the team could be locked for days by
        # a mis-tap, since freeing a slot otherwise needs level 40.
        state = load_state()
        active = state.get("active")
        benched = bench(state)
        if len(sys.argv) < 3:
            members = ", ".join(f"{m['name']} Lv.{m['level']} ({m['species_id']})"
                                for m in ([active] if active else []) + benched)
            print(f"Name who goes to the PC: deposit <species_id>. Team: {members or 'empty'}")
            return 1

        wanted = int(sys.argv[2])
        from_active = bool(active) and wanted in (active["species_id"],
                                                  active.get("base_species_id"))
        index = next((i for i, m in enumerate(benched)
                      if wanted in (m["species_id"], m.get("base_species_id"))), None)
        if not from_active and index is None:
            print(f"{wanted} is not on the team.")
            return 1

        # Depositing the one being trained hands training to the bench, because
        # the panel has no state for having no active Pokemon.
        if from_active and not benched:
            print(f"{active['name'].capitalize()} is the only one on the team. "
                  f"Add another before putting it away.")
            return 1

        going = active if from_active else benched.pop(index)

        # "stored" only ever applies to a chain that never earned its place.
        # One that was trained to the floor, maxed out or awarded keeps that,
        # whether it is coming back from a withdrawal or was filed at level 100
        # and is still on the team.
        base = going.get("base_species_id")
        existing = next((p for p in state["pokedex"] if entry_base(p) == base), None)
        source = (going.get("filed_source")
                  or (existing or {}).get("source")
                  or "stored")
        file_in_pc(state, going, source)

        if from_active:
            state["active"] = benched.pop(0)
        update_display(state)
        save_state(state)
        print(f"{going['name'].capitalize()} Lv.{going['level']} is in the PC "
              f"({party_slots_used(state)}/{PARTY_SIZE}). "
              f"Now training {state['active']['name']}.")

    elif command == "claim":
        # Spends a reward earned by starting a new project. The Pokemon goes
        # straight into the Pokedex marked as awarded, so it never passes for
        # one that was actually raised to 100.
        state = load_state()
        if state.get("unclaimed", 0) <= 0:
            print("Nothing to claim.")
            return 1

        species_id = int(sys.argv[2])
        base = evolution_line(species_id)[0]
        if any(p["species_id"] == base["species_id"] for p in state["pokedex"]):
            print(f"{base['name'].capitalize()} is already in the Pokedex.")
            return 1

        shiny = random.randrange(SHINY_CHANCE) == 0
        state["pokedex"].append({
            "species_id": base["species_id"],
            "name": base["name"],
            "level": 1,
            "source": "project",
            "shiny": shiny,
            "completed_at": datetime.now(timezone.utc).isoformat(),
        })
        register_species(state, base["species_id"], base["name"], shiny)
        state["unclaimed"] -= 1
        update_display(state)
        save_state(state)
        print(f"Claimed {base['name']}. {state['unclaimed']} left.")

    elif command == "evolve":
        # Resolves a branching stage: the trainer names the form to become.
        state = load_state()
        active = state.get("active")
        pending = (active or {}).get("pending_evolution")
        if not pending:
            print("No evolution is waiting for a choice.")
            return 1

        # With a single option the id may be omitted: the panel calls it that
        # way once the animation finishes.
        if len(sys.argv) > 2:
            wanted = int(sys.argv[2])
        elif len(pending["options"]) == 1:
            wanted = pending["options"][0]["species_id"]
        else:
            names = ", ".join(f"{o['name']} ({o['species_id']})" for o in pending["options"])
            print(f"This stage branches. Choose from: {names}")
            return 1

        target = next((o for o in pending["options"] if o["species_id"] == wanted), None)
        if target is None:
            names = ", ".join(f"{o['name']} ({o['species_id']})" for o in pending["options"])
            print(f"{wanted} is not one of the options. Choose from: {names}")
            return 1

        was = active["name"]
        active.setdefault("choices", {})[str(pending["stage"])] = wanted
        active["species_id"] = target["species_id"]
        active["name"] = target["name"]
        active["announced_stage"] = None
        # A new form is a new Pokedex entry — the old one stays registered.
        register_species(state, target["species_id"], target["name"],
                         bool(active.get("shiny")))

        events = [{"type": "evolution", "from": was, "to": target["name"],
                   "species_id": target["species_id"],
                   "at": datetime.now(timezone.utc).isoformat()}]
        # Recomputes level, catches at 100, and re-checks whether the new form
        # already qualifies for the stage after this one.
        events += apply_xp(state, 0)
        state["events"] = (state.get("events", []) + events)[-50:]
        update_display(state)
        save_state(state)
        print(f"{was} -> {state['active']['name']} Lv.{state['active']['level']}")

    elif command == "test-notification":
        # Appends a synthetic event so the menu bar app posts a real banner
        # through its own bundle id. Useful to confirm macOS is showing them
        # without waiting for an actual evolution.
        state = load_state()
        active = state.get("active") or {}
        state.setdefault("events", []).append({
            "type": "evolution",
            "from": active.get("name", "charmeleon"),
            "to": active.get("name", "charizard"),
            "species_id": active.get("species_id", 6),
            "at": datetime.now(timezone.utc).isoformat(),
        })
        state["events"] = state["events"][-50:]
        save_state(state)
        print("Test event queued. Open the menu bar panel, or wait up to 30s.")

    elif command == "cry":
        active = load_state().get("active")
        if active:
            path = ensure_cry(active["species_id"])
            if path:
                subprocess.Popen(["afplay", path],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    elif command == "choose":
        state = load_state()
        active = state.get("active")
        force = "--force" in sys.argv
        keep_xp = "--keep-xp" in sys.argv
        carried_xp = active["xp"] if (active and keep_xp) else 0

        # Swapping normally resets XP to zero, so it is only allowed once the
        # current Pokemon is maxed out (and therefore already in the Pokedex).
        # With --keep-xp nothing is discarded, so the guard does not apply.
        if active and active["level"] < MAX_LEVEL and not force and not keep_xp:
            print(f"{active['name'].capitalize()} is at level {active['level']}, "
                  f"not {MAX_LEVEL}. Swapping now would discard "
                  f"{active['xp']:,} XP. Pass --force to discard it, or "
                  f"--keep-xp to carry it over.")
            return 1

        ensure_active(state, species_id=int(sys.argv[2]))
        if carried_xp:
            # apply_xp recomputes the level from total XP and applies whatever
            # evolutions that level has already earned on the new line.
            apply_xp(state, carried_xp)

        # Must refresh here: the statusline and the menu bar read the cached
        # display block, so without this they would keep showing the old
        # Pokemon until the next scan.
        update_display(state)
        save_state(state)
        new = state["active"]
        print(f"New active: {new['name']} Lv.{new['level']} ({new['xp']:,} XP)")

    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
