# Trying ReMynd in your assistant — internal

Ten minutes, one command. Afterwards you can ask Claude "what did I do yesterday?"
and it answers from your own screen history.

## Before you start

- macOS 14 or later
- ReMynd installed and **recording for at least a few hours** — a fresh install
  connects fine but has nothing to remember yet
- Claude Desktop (best supported today), and/or Claude Code, Cursor, Gemini CLI, Codex

Nothing else. No Homebrew, Python, node, account or API key.

## Install

```bash
bash <(curl -fsSL https://remyndai.com/claude/install.sh)
```

Then **restart the app you want to use** — Claude Desktop will not see it until it
relaunches. Ask it "what was I working on yesterday afternoon?" to check.

## What it puts on your Mac

| Location | What |
|---|---|
| `~/.remynd-sync/` | The server, the retrieval CLI, config. ~500 KB. |
| `claude_desktop_config.json` | One entry. Backed up first; existing entries preserved. |
| `~/.claude/`, `~/.codex/` | Only if present — hooks and a skill, or a block. |

Remove everything: `bash <(curl -fsSL https://remyndai.com/claude/install.sh) --uninstall`.
Recordings are never touched. To pause instead, set `enabled=0` in `~/.remynd-sync/config`.

## What gets sent

Your activity goes to **your own assistant, as part of your own requests, and nowhere
else** — no ReMynd server sees it, and the database is opened read-only.

Screen text is included, not just app names; that is what makes it useful.
Credential-shaped text (keys, tokens, `password=`, card numbers) is stripped first.
Your agent's own terminal is skipped so it does not read its own output back. Anything
ReMynd never recorded — incognito, or while paused — cannot appear.

To hold something back, add app names or domains to `sync_exclude` in the config.

## Known rough edges

- **Claude Desktop** works well; try it first.
- **Claude Code** gets a richer setup: context arrives every session, no tool call needed.
- **Cursor / Gemini CLI / Codex** are wired but less exercised.
- **ChatGPT** needs two things: a public endpoint (`remynd-remote start` publishes one through
  *your own* Cloudflare tunnel and prints a URL; requires `cloudflared`) **and a paid ChatGPT
  plan**. Custom connectors are Plus / Pro / Business / Enterprise / Edu only — on Free there is
  no Connectors section to paste the URL into. The server side is done and verified against
  ChatGPT's contract; the plan is the only thing in the way.
- **The in-app setup button** is built but not shipped (open PR), so use the command above.
- **If ReMynd itself will not launch**, there is an open production crash on startup
  (`SandboxCustomAppBridge.listCalls`) unrelated to this. Flag it rather than fighting it.

## Feedback that helps

An answer that was **wrong** (with the question and what you expected), anything
**slow** or needing many tool calls, and above all anything that made you
**uncomfortable** about what it could see.

Logs: `~/.remynd-sync/` and `~/Library/Logs/Claude/mcp-server-remynd.log`.
