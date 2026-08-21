# Showing your Pokémon in the Claude Code status line

The menu bar hides itself in full-screen apps — exactly when you are heads-down
generating XP. The status line covers that gap, and costs effectively nothing.

## Why it reads a file instead of calling the engine

The status line command runs on every redraw, several times per second. A scan
costs ~130ms and even spawning `jq` costs ~41ms, either of which you would feel
while typing.

So the engine does the work once per scan and writes a single pre-rendered,
tab-separated line to `~/.claude/pokemon-statusline`:

```
🔥→Charizard→82→84        (→ are tabs)
```

The status line reads it with bash's `read` builtin — no subprocess at all.
Measured over 10 runs, adding this section changed total time by less than the
run-to-run noise.

## Setup

Add this near the end of your status line script, just before it echoes the
assembled string. Placing it last puts your Pokémon at the far right.

```bash
# Pokemon in training. Reads only the pre-rendered line written by the engine;
# never invokes it, and never spawns jq.
poke_line="$HOME/.claude/pokemon-statusline"
if [ -f "$poke_line" ]; then
  IFS=$'\t' read -r p_emoji p_name p_level p_pct < "$poke_line"
  if [ -n "$p_name" ]; then
    p_filled=$((p_pct / 10))
    [ "$p_filled" -gt 10 ] && p_filled=10
    p_bar=""
    for ((i=0; i<p_filled; i++)); do p_bar="${p_bar}█"; done
    for ((i=p_filled; i<10; i++)); do p_bar="${p_bar}░"; done
    [ -n "$parts" ] && parts="${parts}  |  "
    parts="${parts}${p_emoji} ${p_name} Lv.${p_level} [${p_bar}] ${p_pct}%"
  fi
fi

echo "$parts"
```

Adjust `parts` and the separator to match your own script's variable names.

If you have no status line yet, point `statusLine` at a script in
`~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline-command.sh"
  }
}
```

## Keeping it fresh

The file is rewritten every time the engine runs, which the menu bar app does
every 30 seconds. If you are not running the app, refresh it yourself — for
example from a `Stop` hook, or on a timer:

```bash
python3 /path/to/train-your-pokemon/engine/poketrainer.py scan
```
