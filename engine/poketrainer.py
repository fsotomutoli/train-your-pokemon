#!/usr/bin/env python3
"""Train Your Pokemon engine.

Reads Claude Code transcripts, converts work tokens into XP, and maintains the
active Pokemon plus the Pokedex in ~/.claude/pokemon-state.json.

Usage:
    poketrainer.py scan          # incremental update (normal use)
    poketrainer.py backfill      # re-read the whole history from scratch
    poketrainer.py status        # print state as JSON
    poketrainer.py choose <id>   # switch the active Pokemon
"""

import json
import os
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

CLAUDE_DIR = Path.home() / ".claude"
PROJECTS_DIR = CLAUDE_DIR / "projects"
STATE_PATH = CLAUDE_DIR / "pokemon-state.json"
STATUSLINE_PATH = CLAUDE_DIR / "pokemon-statusline"

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

# Synthetic levels for evolutions that are not level-based (stones, trade,
# friendship). Without this, Eevee and Pikachu would never evolve.
SYNTHETIC_EVO_LEVEL = {1: 16, 2: 36}

MAX_LEVEL = 100

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
    """Flatten the evolution chain into a linear list with each hop's level.

    For branching chains (Eevee) the first branch is taken; the alternatives are
    kept under 'branches' so the UI can offer them later.
    """
    species = get_species(species_id)
    chain_id = _id_from_url(species["evolution_chain"]["url"])
    chain = get_evolution_chain(chain_id)["chain"]

    stages = [{"species_id": _id_from_url(chain["species"]["url"]),
               "name": chain["species"]["name"],
               "min_level": None,
               "branches": []}]

    node = chain
    stage = 1
    while node["evolves_to"]:
        options = node["evolves_to"]
        chosen = options[0]
        details = chosen["evolution_details"][0] if chosen["evolution_details"] else {}
        level = details.get("min_level") or SYNTHETIC_EVO_LEVEL.get(stage, 36)
        stages.append({
            "species_id": _id_from_url(chosen["species"]["url"]),
            "name": chosen["species"]["name"],
            "min_level": level,
            "branches": [{"species_id": _id_from_url(o["species"]["url"]),
                          "name": o["species"]["name"]} for o in options],
        })
        node = chosen
        stage += 1

    return stages


def ensure_sprites(species_id, kinds=("animated", "artwork")):
    """Download the requested sprites once. Returns paths.

    `kinds` exists so bulk callers can skip the official artwork: it is ~150KB
    per species against ~20KB for the animated sprite, and the candidate grid
    only ever renders the small one.
    """
    SPRITES_DIR.mkdir(parents=True, exist_ok=True)
    paths = {}
    for key, url, ext in (
        ("animated", f"{SPRITE_BASE}/versions/generation-v/black-white/animated/{species_id}.gif", "gif"),
        ("artwork", f"{SPRITE_BASE}/other/official-artwork/{species_id}.png", "png"),
    ):
        if key not in kinds:
            continue
        target = SPRITES_DIR / f"{species_id}-{key}.{ext}"
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

def collect_tokens(state, from_scratch=False):
    """Scan the .jsonl transcripts and return {date: work_tokens} for new data."""
    if from_scratch:
        state["cursors"] = {}
        state["recent_msg_ids"] = []

    cursors = state["cursors"]
    seen = set(state.get("recent_msg_ids", []))
    seen_order = list(state.get("recent_msg_ids", []))
    per_day = {}

    if not PROJECTS_DIR.exists():
        return per_day

    for path in sorted(PROJECTS_DIR.rglob("*.jsonl")):
        key = str(path)
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
    return per_day


# --------------------------------------------------------------------------
# Progression
# --------------------------------------------------------------------------

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
        "line": line,
        "started_at": datetime.now(timezone.utc).isoformat(),
    }
    return state["active"]


def apply_xp(state, gained_xp):
    """Add XP to the active Pokemon, evolve it, and catch it at level 100."""
    active = ensure_active(state)
    curve = xp_curve(active["growth_rate"])
    events = []

    level_before = active["level"]
    active["xp"] = min(active["xp"] + gained_xp, curve[MAX_LEVEL])
    active["level"] = level_from_xp(active["xp"], curve)

    if active["level"] > level_before:
        # Distinct key names on purpose: `from`/`to` carry species names on
        # evolution events, and reusing them for integers here made the whole
        # event list fail to decode in the Swift app, blanking the menu bar.
        events.append({"type": "level_up",
                       "from_level": level_before, "to_level": active["level"],
                       "at": datetime.now(timezone.utc).isoformat()})

    # Evolution: the most advanced stage whose level has already been reached.
    target = active["line"][0]
    for stage in active["line"]:
        if stage["min_level"] is None or active["level"] >= stage["min_level"]:
            target = stage
    if target["species_id"] != active["species_id"]:
        events.append({"type": "evolution", "from": active["name"], "to": target["name"],
                       "species_id": target["species_id"],
                       "at": datetime.now(timezone.utc).isoformat()})
        active["species_id"] = target["species_id"]
        active["name"] = target["name"]

    # Heads-up one level before evolving, so the change is not a surprise.
    upcoming = next((s for s in active["line"]
                     if s["min_level"] and s["min_level"] > active["level"]), None)
    if upcoming and active["level"] >= upcoming["min_level"] - 1:
        events.append({"type": "pre_evolution", "from": active["name"],
                       "to": upcoming["name"], "level": upcoming["min_level"],
                       "at_level": active["level"],
                       "at": datetime.now(timezone.utc).isoformat()})

    # Level 100: goes into the Pokedex and becomes swappable.
    if active["level"] >= MAX_LEVEL and not active.get("completed_at"):
        active["completed_at"] = datetime.now(timezone.utc).isoformat()
        already = {p["species_id"] for p in state["pokedex"]}
        if active["species_id"] not in already:
            state["pokedex"].append({
                "species_id": active["species_id"],
                "name": active["name"],
                "level": MAX_LEVEL,
                "completed_at": active["completed_at"],
            })
        events.append({"type": "caught", "who": active["name"],
                       "species_id": active["species_id"],
                       "at": active["completed_at"]})

    state["events"] = (state.get("events", []) + events)[-50:]
    return events


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
        "caught": len(state["pokedex"]),
        "next_evo": next_stage["name"] if next_stage else None,
        "next_evo_level": next_stage["min_level"] if next_stage else None,
        "sprites": ensure_sprites(active["species_id"]),
        # Cached here so the menu bar app can play it on open without paying
        # the cost of spawning Python.
        "cry": ensure_cry(active["species_id"]),
    }

    # Flat line for the statusline, read with bash's `read` builtin so no
    # process is spawned. Spawning jq cost ~41ms per redraw; this costs ~0.
    display = state["display"]
    fields = [display["emoji"], display["name"].capitalize(),
              str(display["level"]), str(display["pct"])]
    tmp = STATUSLINE_PATH.with_suffix(".tmp")
    tmp.write_text("\t".join(fields) + "\n", encoding="utf-8")
    os.replace(tmp, STATUSLINE_PATH)


GEN1_MAX = 151
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
    listing = _get_json(f"{POKEAPI}/evolution-chain?limit=80", "chain-list")

    forms = []
    for entry in listing["results"]:
        chain_id = _id_from_url(entry["url"])
        try:
            chain = get_evolution_chain(chain_id)["chain"]
        except Exception:
            continue
        species_id = _id_from_url(chain["species"]["url"])
        if species_id <= GEN1_MAX:
            forms.append({"species_id": species_id, "name": chain["species"]["name"]})

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

    available = [f for f in base_forms() if f["species_id"] not in caught_bases]
    for form in available:
        # Only the small sprite: the grid never shows the 475px artwork, and
        # fetching both for ~70 species is what made the first run take 2min.
        form["sprites"] = ensure_sprites(form["species_id"], kinds=("animated",))
    return available


def scan(from_scratch=False):
    state = load_state()
    if from_scratch:
        state = empty_state()

    per_day = collect_tokens(state, from_scratch=from_scratch)
    new_work = sum(per_day.values())

    if new_work == 0:
        # Even with no new tokens the display must refresh: the day rolls over
        # (today_xp resets) and sprites may still be missing.
        ensure_active(state)
        update_display(state)
        save_state(state)
        return state, []

    for date, tokens in per_day.items():
        state["daily"][date] = state["daily"].get(date, 0) + tokens // TOKENS_PER_XP

    gained_xp = new_work // TOKENS_PER_XP
    state["totals"]["work_tokens"] += new_work
    state["totals"]["xp_all_time"] += gained_xp

    events = apply_xp(state, gained_xp)
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

    elif command == "candidates":
        # Written to the state file so the menu bar app reads it the same way
        # it reads everything else, instead of parsing stdout.
        state = load_state()
        state["candidates"] = candidates(state)
        save_state(state)
        print(f"{len(state['candidates'])} available")

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
