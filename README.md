# Train Your Pokémon

Turns your Claude Code token usage into a Pokémon that levels up and evolves,
shown in the macOS menu bar and in the Claude Code status line. Reach level 100
and it joins your Pokédex, so you can start raising the next one.

```
menu bar   [🔥 Lv.82]  🔋  📶  🔍   14:03
statusline 🌿 main  |  🤖 Opus 5  |  🔥 Charizard Lv.82 [████████░░] 84%
```

No dependencies beyond what macOS ships: the engine is stdlib-only Python, the
menu bar app is SwiftUI built with the Command Line Tools, and sprites, cries
and evolution data come from [PokéAPI](https://pokeapi.co).

## How it works

Claude Code writes a JSONL transcript per session under `~/.claude/projects/`.
The engine reads those incrementally, converts token usage into XP, and writes a
single state file that both frontends read.

```
~/.claude/projects/*.jsonl
          │
          ▼
  engine/poketrainer.py  ──▶  ~/.claude/pokemon-state.json
                                        │
                        ┌───────────────┴───────────────┐
                        ▼                               ▼
                 menu bar app                    Claude Code
                 (SwiftUI)                       status line
```

## The interesting parts

**Not all tokens are work.** `cache_read` accounts for ~98% of raw token volume
and grows with context length rather than with effort, so counting it would put
any Pokémon at level 100 on day one. XP comes from `output_tokens +
cache_creation_input_tokens` only.

**The transcript repeats itself.** Claude Code writes one line per content block
and each line carries the full `usage` payload, so naive summing inflates totals
by ~2.5x. Everything is deduplicated by `message.id`.

**Not every evolution has a level.** PokéAPI returns `min_level: null` for
evolutions triggered by stones, trade or friendship — without a fallback, Eevee
and Pikachu would never evolve. Those get synthetic levels (16 and 36).

**The status line runs several times per second.** It never invokes the engine;
it reads a pre-rendered tab-separated line with bash's `read` builtin. An earlier
version shelled out to `jq` and cost 41ms per redraw.

**Menu bar icons are 24pt tall.** A whole sprite scaled to fit is unreadable, so
the icon crops to the Pokémon's face and scales that up. Gen-5 sprites are
pre-normalised to a near-square box (Onix is drawn coiled, not tall), so the
framing generalises across body plans by anchoring the crop a third of the way
down — top-anchoring cuts the eyes off quadrupeds.

**Cries play without a converter.** PokéAPI serves them as Ogg Vorbis, which
macOS CoreAudio decodes natively, so `afplay` handles them directly.

## Install

Requires macOS 13+ and Xcode Command Line Tools (`xcode-select --install`).
Full Xcode is *not* needed — a WidgetKit widget would require it, a
`MenuBarExtra` app does not.

```bash
git clone https://github.com/fsotomutoli/train-your-pokemon.git
cd train-your-pokemon

python3 engine/poketrainer.py backfill   # convert your history into XP
bash app/build.sh                        # build the menu bar app
bash install.sh                          # start it, and start it at login
```

To show your Pokémon in the Claude Code status line as well, see
[`docs/statusline.md`](docs/statusline.md).

## Commands

```bash
python3 engine/poketrainer.py scan               # incremental update (~0.1s)
python3 engine/poketrainer.py backfill           # re-read all history
python3 engine/poketrainer.py status             # dump state as JSON
python3 engine/poketrainer.py candidates         # list species you can train
python3 engine/poketrainer.py choose 4           # switch species (level 100 only)
python3 engine/poketrainer.py choose 4 --keep-xp # switch, carrying XP over
python3 engine/poketrainer.py cry                # play the current cry
python3 engine/poketrainer.py test-notification  # queue a test banner
```

## Tuning

XP pace lives in one constant in `engine/poketrainer.py`:

```python
TOKENS_PER_XP = 50   # lower = faster levelling
```

At 50, roughly 26 active days of heavy use reach level 100. Adjust to taste,
then re-run `backfill`.

Menu bar framing lives in `app/Sources/Sprites.swift`:

```swift
static let canvasHeight: CGFloat = 24   // icon height
static let headFraction: CGFloat = 0.58 // how much of the sprite is framed
static let cropAnchor:   CGFloat = 0.34 // where the crop window sits
static let maxWidth:     CGFloat = 36   // widest the sprite may get
static let trailingGap:  CGFloat = 6    // space before the level text
```

`app/preview.swift` renders icons to a contact sheet so framing can be checked
without screenshotting the menu bar.

## A caveat worth naming

This rewards consumption. If it works, it nudges you toward burning tokens for
the dopamine, which is not obviously a good thing. A daily XP cap would fix that
and is deliberately not implemented — decide for yourself.

## License

MIT. Pokémon and its sprites, names and cries are trademarks of Nintendo /
Creatures Inc. / GAME FREAK Inc.; this is an unofficial fan project with no
affiliation, distributed for personal use.
