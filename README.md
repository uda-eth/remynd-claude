# ReMynd × Claude Code

Wire your [ReMynd](https://remyndai.com) "second brain" into [Claude Code](https://claude.com/claude-code)
as an **always-on context source** — so Claude boots up already knowing your recent activity.

## Install

```bash
bash <(curl -fsSL https://remyndai.com/claude/install.sh)
```

or, straight from this repo:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/uda-eth/remynd-claude/main/install.sh)
```

Re-running is safe (idempotent). It only ever writes inside `~/.claude`.

## What it sets up

- **SessionStart hook** — every Claude Code session starts with your `CRITICAL_FACTS` + vault index
  loaded automatically (your recent apps, people, projects — distilled from your screen history).
- **`/brain` skill** — on-demand deep retrieval: navigates your vault's notes and runs read-only
  full-text search / SQL over your OCR timeline (`app.db`). Ask "what was I doing on June 20?" and
  Claude answers from your own history.

Your ReMynd data profile (production or dev) is detected automatically — nothing is hardcoded.

## Requirements

- macOS
- [Claude Code](https://claude.com/claude-code) installed (`~/.claude` exists)
- [`jq`](https://jqlang.github.io/jq/) (`brew install jq`)
- ReMynd installed and recording (the context activates automatically once a vault has synthesized)

## Notes

- **Read-only.** The setup never writes to your ReMynd data — it only reads it.
- **Local & private.** Your activity is injected into *your* Claude Code sessions on *your* machine.
  Nothing leaves your computer beyond your normal Claude requests.
- **New installs stay quiet at first.** A fresh ReMynd hasn't synthesized a brain yet; the hook
  activates automatically once it has.
- After installing, **start a new Claude Code session** (or run `/clear`) for the hook to take effect.

## Uninstall

Remove the `SessionStart` hook block from `~/.claude/settings.json`, then:

```bash
rm -rf ~/.claude/remynd ~/.claude/skills/brain
```
