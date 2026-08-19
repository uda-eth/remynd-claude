# ReMynd for Claude Code & Codex

Your coding agent forgets everything between sessions. Your Mac doesn't.

[ReMynd](https://remyndai.com) records your screen and reads the text off every frame. This wires
that into [Claude Code](https://claude.com/claude-code) and [Codex](https://openai.com/codex), so
your agent starts every session already knowing what you were working on — and **keeps knowing it as
you work**, not just at the moment the session opened.

```bash
bash <(curl -fsSL https://remyndai.com/claude/install.sh)
```

macOS, and nothing else to install. No jq, no Homebrew, no Python, no API key, no account.

---

## What changes

**Before.** You open Claude Code and re-explain the bug you've been chasing for an hour, the error
message you saw, the doc page you had open.

**After.** It already knows. Ask *"what was that error I hit before lunch?"* and it answers from what
was actually on your screen.

Two things get installed:

**Always-on context.** Every session opens with a digest of what you've been doing — apps, windows,
pages, and the verbatim text that was on screen. As you keep working, it's topped up: switch to Xcode
for two minutes, and your *next* prompt carries that. It never goes stale mid-session.

**The `/remynd` skill.** On-demand retrieval over everything you've ever seen:

```
> what was I doing on Tuesday afternoon?
> find that Stripe webhook error from last week
> how much time did I actually spend in Slack this month?
```

---

## The `remynd` command

The same retrieval your agent uses, available to you directly:

```
remynd now                     what you're doing right now
remynd recent 60               digest of the last 60 minutes
remynd search "stripe webhook" full-text search everything you've seen
remynd day 2026-08-13          reconstruct a day
remynd apps 7                  where your time actually went
remynd text "13:30" "13:45"    verbatim screen text from a stretch of time
remynd status                  what's connected, and how fresh
```

`remynd search` gives you timestamps; feed one into `remynd text` to read everything that was on
screen around it. That's how you find the thing you half-remember.

---

## What gets sent, and what doesn't

Worth being precise about, because this is your screen.

**Everything ReMynd captured is in scope, including the text on your screen.** Not a summary of it —
the actual words. That's the point: an agent that only knows which apps you opened isn't much use.

**It goes to your agent, as part of your own requests. Nowhere else.** No ReMynd server, no third
party, no telemetry. The database is read locally and never modified.

**Credential-shaped strings are stripped first.** API keys, tokens, `password=` lines, card numbers —
replaced with `<redacted>` before anything leaves your machine. That's roughly 0.1% of text volume,
and it's on by default. Turn it off in `~/.remynd-sync/config` if you'd rather send literally
everything.

**What ReMynd never recorded can't appear.** Incognito browser windows are excluded by ReMynd itself
unless you opted in, and anything captured while recording was paused simply doesn't exist.

**You can carve out more.** ReMynd has no per-app capture exclusion, so this ships its own:
`sync_exclude` in the config takes app names and domains that are recorded but never sent. It's empty
by default.

**Turn it off any time**: set `enabled=0` in `~/.remynd-sync/config`, or remove it completely:

```bash
bash <(curl -fsSL https://remyndai.com/claude/install.sh) --uninstall
```

---

## Cost

An idle session costs **nothing**. If you haven't done anything since your last prompt, the hook
emits zero bytes.

When you have, you pay for what actually happened: roughly 820 tokens per active minute, so a typical
1–3 minute gap between prompts is a 0.8–2.5k token update. There's a per-session ceiling (35% of the
context window by default). Past it, updates fall back to activity headlines — and say so, once. The
text is never lost; it's one `/remynd` call away.

All of it is tunable in `~/.remynd-sync/config`.

---

## Install options

```bash
bash <(curl -fsSL https://remyndai.com/claude/install.sh)          # detects what you have
bash <(curl -fsSL https://remyndai.com/claude/install.sh) --claude # Claude Code only
bash <(curl -fsSL https://remyndai.com/claude/install.sh) --codex  # Codex only
bash <(curl -fsSL https://remyndai.com/claude/install.sh) --all    # both
```

Re-running is safe. Your `settings.json` is backed up before it's touched, and restored if anything
goes wrong.

**As a Claude Code plugin**, if you'd rather have versioned updates:

```
/plugin marketplace add uda-eth/remynd-claude
/plugin install remynd@remynd
```

### Claude Code vs Codex

Claude Code gets the full experience: context at session start **and** a top-up before every prompt,
via its `SessionStart` and `UserPromptSubmit` hooks.

Codex has no per-prompt hook, so it gets context at session start (through a generated block in
`~/.codex/AGENTS.md`) plus the `remynd` command, which it runs itself when it needs something. Fresh
on demand rather than pushed — the same data either way.

---

## Requirements

- macOS 14 or later
- [ReMynd](https://remyndai.com), installed and having recorded for a while
- Claude Code and/or Codex

A brand-new ReMynd has nothing to say yet. The install stays quiet and starts working on its own once
there's history.

---

## How it works

- **`SessionStart`** injects the opening digest. Deliberately not filtered on event source, so it
  also fires after `/compact` — otherwise compaction would quietly drop your context for the rest of
  the session.
- **`UserPromptSubmit`** compares a per-session watermark against the database. Nothing new, no
  output. Something new, it sends only that.
- **Watermarks are rowids, not timestamps.** `app.db` has no index on any time column, so filtering
  by time full-scans ~873k rows (~4 seconds). Bounding by rowid first makes it ~29ms.
- **Times are stored in UTC** and converted to local for display. Bypassing the `remynd` command to
  query `app.db` directly will silently shift every window by your UTC offset.

Read-only throughout: the database is opened with `mode=ro`, and the recorder keeps writing while you
read it.

## Testing

```bash
tests/acceptance.sh
```

Runs the nine acceptance criteria from [the PRD](docs/PRD-always-hot.md) against a real profile —
silence when idle, OCR in deltas, budget behaviour, read-only guarantees, credential redaction.
