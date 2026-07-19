#!/usr/bin/env bash
#
# ReMynd × Claude Code — one-command setup
# --------------------------------------------------------------------------
# Wires your ReMynd "second brain" into Claude Code as an always-on context
# source, so Claude boots up already knowing your recent activity:
#
#   • SessionStart hook  — loads your CRITICAL_FACTS + index every session
#   • /brain skill       — deep retrieval over your vault + OCR timeline
#
# Auto-detects your ReMynd data profile (production or dev). Safe to re-run
# (idempotent). Only ever writes inside ~/.claude — never your ReMynd data.
#
# Usage:   bash <(curl -fsSL https://remyndai.com/claude/install.sh)
#   or:    ./install.sh
# --------------------------------------------------------------------------
set -euo pipefail

say()  { printf '\033[1;36m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || die "ReMynd is macOS-only, so is this setup."
CLAUDE_DIR="$HOME/.claude"
[ -d "$CLAUDE_DIR" ] || die "~/.claude not found. Install Claude Code first: https://claude.com/claude-code"
command -v jq >/dev/null 2>&1 || die "jq is required. Install it with:  brew install jq"

REMYND_DIR="$CLAUDE_DIR/remynd"
SKILL_DIR="$CLAUDE_DIR/skills/brain"
SETTINGS="$CLAUDE_DIR/settings.json"
mkdir -p "$REMYND_DIR" "$SKILL_DIR"

# ---------------------------------------------------------------- 1. profile detection lib
cat > "$REMYND_DIR/remynd-lib.sh" <<'LIB'
#!/usr/bin/env bash
# Prints the path of the best ReMynd data profile on this machine, or exits 1.
# Scoring prefers: a synthesized vault > a vault dir > an OCR db; production > dev build.
remynd_find_profile() {
  local base="$HOME/Library/Application Support/Move37"
  [ -d "$base" ] || return 1
  local best="" bestscore=-1 d score name
  for d in "$base"/ReMynd-* "$base"/ScreenomeX-*; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    score=0
    [ -f "$d/SecondBrain/CRITICAL_FACTS.md" ] && score=$((score+4))
    [ -d "$d/SecondBrain" ]                   && score=$((score+2))
    [ -f "$d/Recordings/app.db" ]             && score=$((score+1))
    case "$name" in *-dev-*|*-dev) ;; *) score=$((score+2)) ;; esac  # prefer production
    if [ "$score" -gt "$bestscore" ]; then bestscore=$score; best="$d"; fi
  done
  [ -n "$best" ] && [ "$bestscore" -ge 2 ] || return 1
  printf '%s\n' "$best"
}
LIB

# ---------------------------------------------------------------- 2. SessionStart hook backend
cat > "$REMYND_DIR/session-context.sh" <<'CTX'
#!/usr/bin/env bash
# Emits the always-on ReMynd brain context as a Claude Code SessionStart payload.
# No-ops silently (exit 0) if jq/profile/vault aren't present yet.
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$dir/remynd-lib.sh"
command -v jq >/dev/null 2>&1 || exit 0
profile="$(remynd_find_profile)" || exit 0
brain="$profile/SecondBrain"
[ -f "$brain/CRITICAL_FACTS.md" ] || exit 0
{
  echo "# ReMynd Second Brain — always-on context"
  echo "Source: $brain (live, synthesized from your screen history). Treat synthesized NUMBERS as leads, not ground truth; use the /brain skill to verify against the OCR timeline."
  echo; echo "## CRITICAL_FACTS.md"; cat "$brain/CRITICAL_FACTS.md"
  [ -f "$brain/index.md" ] && { echo; echo "## index.md"; cat "$brain/index.md"; }
} | jq -Rs '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:.}}'
CTX
chmod +x "$REMYND_DIR/session-context.sh"

# ---------------------------------------------------------------- 3. /brain skill
cat > "$SKILL_DIR/SKILL.md" <<'SKILL'
---
name: brain
description: Retrieve from the user's ReMynd "second brain" — their own screen history, distilled. Use when a question is about what THEY did/saw/worked on, who they talked to, what an app/person/site/project is in their life, or "what was I doing on <date>". Two layers — a curated Obsidian vault (people/apps/concepts/daily notes) and the raw OCR timeline in app.db (full-text searchable). Read-only.
---

# ReMynd brain retrieval

ReMynd records the user's screen, OCRs it, and distills a "second brain" you can read as an
always-available context source. **Everything here is READ-ONLY** — the running app owns these files;
never write to them.

## Locate the profile (do this first)

```bash
PROFILE="$(bash -c '. "$HOME/.claude/remynd/remynd-lib.sh"; remynd_find_profile')"
BRAIN="$PROFILE/SecondBrain"
DB="$PROFILE/Recordings/app.db"
```
If `$PROFILE` is empty, ReMynd isn't installed or hasn't recorded yet — say so rather than guessing.

## Layer 1 — the curated vault (start here for "who/what is X")

1. `cat "$BRAIN/index.md"` — the map of what exists.
2. `cat "$BRAIN/CRITICAL_FACTS.md"` — always-loaded recent-activity snapshot.
3. Follow `[[wikilinks]]` into `wiki/entities/{people,apps,domains}/`, `wiki/concepts/`, `wiki/daily/<YYYY-MM-DD>.md`.
4. `raw/<date>/` holds immutable 30-min OCR digests — cite, don't edit.

## Layer 2 — the raw OCR timeline (app.db) for depth / dates / search

Open **read-only** (WAL allows concurrent readers while the app runs):
`sqlite3 "file:$DB?mode=ro" "<query>"`

Full-text search over OCR'd screen text:
```sql
SELECT s.firstSeenAt, s.displayText
FROM OCRTextSegment s
WHERE s.id IN (SELECT rowid FROM OCRTextSegment_FTS WHERE OCRTextSegment_FTS MATCH 'invoice OR stripe')
ORDER BY s.firstSeenAt DESC LIMIT 40;
```
"What did I do on a given day":
```sql
SELECT firstSeenAt, displayText FROM OCRTextSegment
WHERE firstSeenAt >= '2026-06-20' AND firstSeenAt < '2026-06-21'
ORDER BY firstSeenAt LIMIT 200;
```
App usage over time: `FocusedWindow` (applicationName, windowTitle, startedAt/endedAt) and the
`ActiveApplication` view. Some installs also have a legacy `FrameOCR`/`OCRText` path (search
`FrameOCR_FTS` / `OCRText_FTS`) for their earliest data.

## Caveats (state them when they matter)
- **Don't trust synthesized NUMBERS blindly** — verify counts/durations against app.db before repeating a figure as fact.
- Read-only always. "database is locked" means you opened it writable — re-open with `?mode=ro`.
- Timestamps are LOCAL time. The vault re-synthesizes ~every 30 min, so it may lag the last few minutes.
SKILL

# ---------------------------------------------------------------- 4. merge SessionStart hook (idempotent)
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
jq empty "$SETTINGS" 2>/dev/null || die "$SETTINGS is not valid JSON. Fix it and re-run."
HOOKCMD='bash "$HOME/.claude/remynd/session-context.sh"  # remynd-brain-hook'
tmp="$(mktemp)"
jq --arg cmd "$HOOKCMD" '
  .hooks //= {} | .hooks.SessionStart //= []
  | .hooks.SessionStart |= map(select([.hooks[]?.command // ""] | any(contains("remynd-brain-hook")) | not))
  | .hooks.SessionStart += [{hooks:[{type:"command", command:$cmd, statusMessage:"Loading ReMynd brain…", timeout:15}]}]
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

# ---------------------------------------------------------------- report
echo
say "Installed into ~/.claude:"
echo "    • hooks/SessionStart → remynd/session-context.sh   (always-on context)"
echo "    • skills/brain/SKILL.md                            (/brain deep retrieval)"
if profile="$(bash -c '. "'"$REMYND_DIR"'/remynd-lib.sh"; remynd_find_profile')"; then
  say "Detected your ReMynd profile: $profile"
  if [ -f "$profile/SecondBrain/CRITICAL_FACTS.md" ]; then
    say "Brain vault is ready — Claude will load it next session."
  else
    warn "No brain vault yet. It appears after ReMynd has recorded a while; the hook activates automatically then."
  fi
else
  warn "No ReMynd data found yet. Setup is in place and will activate automatically once ReMynd records some history."
fi
echo
say "Done. Open a new Claude Code session (or run /clear) to load your brain, then type /brain for deep lookups."
