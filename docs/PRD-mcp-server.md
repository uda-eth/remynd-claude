# PRD — ReMynd as an MCP server

**Status:** draft, awaiting sign-off
**Owner:** Tony Udotong
**Date:** 2026-08-19
**Predecessor:** [PRD-always-hot.md](PRD-always-hot.md) — shipped; this generalises it beyond coding agents.

---

## 1. Problem

The agent sync we shipped works, and it only works for coding agents. It is built from Claude Code
hooks and a shell CLI. Every other agent a person actually uses — Claude Desktop, ChatGPT, Gemini,
a personal assistant that texts them over iMessage — cannot see any of it.

That is the wrong shape for what ReMynd is. ReMynd is a memory of what you did. The coding agent is
one consumer of that memory, and probably not the most valuable one. "What did I promise Julian on
that call?" is a better question than anything a code assistant will ask, and today nothing can
answer it except Claude Code.

**The goal: attaching ReMynd to any agent should take one click and no JSON editing.**

## 2. What the protocol actually allows (verified 2026-08-19)

Against the current spec revision, **2026-07-28**:

| | stdio | Streamable HTTP |
|---|---|---|
| Shape | Newline-delimited JSON-RPC over a client-launched subprocess | Single POST endpoint; replies are JSON or a request-scoped SSE stream |
| Reaches | Clients running on the same Mac | Anything that can make an HTTPS request |

Two facts drive the whole design:

- **ChatGPT accepts only remote HTTPS endpoints.** It will not launch a local subprocess. Neither
  will any agent running off-device — which is most iMessage bots.
- **Claude Desktop does both, but not interchangeably.** Local servers go in
  `claude_desktop_config.json`; remote servers must be added through Settings → Connectors, and
  Claude Desktop *will not* connect to a remote server configured in the JSON file. Local servers
  configured that way are also unavailable in Cowork and claude.ai.

The spec's security requirements for HTTP are explicit and non-negotiable:

> Servers **MUST** validate the `Origin` header on all incoming connections to prevent DNS rebinding
> attacks … When running locally, servers **SHOULD** bind only to localhost (127.0.0.1) rather than
> all network interfaces … Servers **SHOULD** implement proper authentication for all connections.

Also relevant: revision 2026-07-28 **removed protocol-level sessions and the GET stream endpoint**,
and the old HTTP+SSE transport is deprecated. A server written today should implement the current
shape and not carry legacy scaffolding.

## 3. The fork this PRD exists to settle

Local reach and remote reach are different products with different privacy claims.

**Local (stdio + loopback HTTP)** covers Claude Desktop, Claude Code, Gemini CLI, Cursor, VS Code.
Nothing leaves the machine that the user's own agent does not send. This is a straight extension of
what we already ship and the privacy story is unchanged.

**Remote (public HTTPS)** is what ChatGPT and an off-device iMessage agent require. It means an
internet-reachable endpoint that reads the user's screen history. That is a materially different
product, and it cannot be described the way we describe the current one.

This PRD proposes shipping **local first and completely**, then treating remote as a separate,
explicitly-consented capability built on the user's own infrastructure — the same shape as Chief's
"your own bucket" architecture, not a ReMynd-operated relay.

## 4. Goals / non-goals

**Goals**
1. One click per client. No hand-edited JSON, no terminal, for the common cases.
2. Works with the app closed, for local clients.
3. No runtime dependency — no node, no Python, no Homebrew, consistent with the current sync.
4. Tool descriptions good enough that a *non-coding* agent knows when to reach for memory.
5. Same retrieval quality as the shipped CLI: the accuracy work carries over, it is not rewritten.
6. Revocable per client, and legible — the user can see what connected and what it asked for.

**Non-goals**
- A ReMynd-hosted relay that proxies user data. If remote happens, it runs on the user's own
  infrastructure.
- Write access of any kind. Read-only remains absolute.
- Replacing the Claude Code hooks. Push-per-prompt is better than pull for that client and stays.

## 5. Architecture

### 5.1 One server, shipped inside the app

`remynd-mcp` is a small Swift binary inside `ReMynd.app/Contents/MacOS/`. It speaks both transports:

- **stdio** when launched by a client as a subprocess.
- **Streamable HTTP on 127.0.0.1** when launched with `--http`, for clients that prefer it.

Shipping it in the bundle rather than as a separate download means: no install step, signed and
notarised with the app, updated with the app, and a stable path clients can point at. It reads
`app.db` directly the way the CLI does, so **it works whether or not ReMynd is running** — which
matters, because a client will launch it on demand.

The retrieval logic is the same logic. The digest builder, the rowid-bounded queries, the timezone
handling, the redaction and the dedupe are all solved and tested; the MCP server is a second
front-end over them, not a reimplementation. Where that code lives is an open question (§10).

### 5.2 Tools

Mirroring the CLI, because the CLI's shape is already validated against real questions:

| Tool | Answers |
|---|---|
| `search_screen_history` | "find that thing I saw about X" |
| `reconstruct_day` | "what did I do on Tuesday" |
| `recent_activity` | "what have I been working on" |
| `screen_text_in_range` | verbatim text for a window, for drilling in |
| `time_by_activity` | "where did my time actually go" |
| `sync_status` | coverage and freshness, so an agent can tell *absent* from *unrecorded* |

**Tool descriptions are the product here.** For Claude Code the skill file teaches retrieval
strategy; an MCP client has only the tool description. Everything the skill learned the hard way has
to be compressed into those strings: that a timestamp is when something was *seen*, not when it
happened; that `search` gives you a cursor and `screen_text_in_range` gives you the substance; that
absence of results is not absence of history.

### 5.3 Connecting, in one click

The Integrations tab already has the connection UI. It gains a per-client row that writes the right
config in the right place:

| Client | What we write |
|---|---|
| Claude Desktop | `claude_desktop_config.json` entry, or a packaged desktop extension |
| Claude Code | already covered by the shipped hooks; offer MCP as an alternative |
| Cursor / VS Code | their MCP config files |
| Gemini CLI | its settings file |
| ChatGPT | requires remote (§5.4) — the row explains why rather than failing silently |

Each row shows connected state and offers disconnect, the same pattern as the shipped Coding agents
row. Every file we touch gets the same treatment as `settings.json` did: backed up, validated,
restored on failure, and never edited if it is not valid JSON.

### 5.4 Remote, if we do it

For ChatGPT and off-device agents, the endpoint must be publicly reachable. The proposal is a
**user-owned tunnel** — the user's own Cloudflare account, their own hostname — with:

- a bearer token minted per client, revocable individually from the Integrations tab;
- `Origin` validation and localhost binding still enforced behind the tunnel;
- a visible indicator in the app while a remote endpoint is live, because an internet-reachable
  window into your screen history should not be a thing you can forget you turned on;
- a scoped default: remote clients get structural activity only, with verbatim screen text behind a
  second, separate consent.

**This changes the privacy claim.** Today we say the data goes to the user's own agent and nowhere
else. With a tunnel, the honest sentence becomes "to your own agent, over your own tunnel, on your
own account." That is defensible, and it is not the same sentence. The alternative is to ship local
only and tell ChatGPT users plainly that it is not supported yet.

## 6. What "incredibly easy" has to mean

Judged from a standing start on a Mac with ReMynd installed:

1. Open Settings → Integrations.
2. See the agents you actually have, detected.
3. Click Connect next to one.
4. Restart that agent. Ask it what you did yesterday.

No terminal. No JSON. No token pasted anywhere. If any client cannot reach that bar, the row says so
in a sentence instead of half-working.

## 7. Milestones

| # | Milestone | Done when |
|---|---|---|
| **M1** | Core extraction | Retrieval logic callable from Swift as well as shell; one implementation, both front-ends, existing accuracy tests still green |
| **M2** | `remynd-mcp` over stdio | Six tools, spec revision 2026-07-28, verified against a real client with the app both running and closed |
| **M3** | Tool-description quality pass | A non-coding agent answers the marathon, Gmail and Ilias questions at parity with the Claude Code skill, graded against the same SQL ground truth |
| **M4** | Loopback Streamable HTTP | `Origin` validated, 127.0.0.1 only, bearer auth, `Mcp-Method`/`Mcp-Name`/`MCP-Protocol-Version` handled, header/body mismatch → `-32020` |
| **M5** | One-click connect | Integrations rows for Claude Desktop, Cursor, VS Code, Gemini CLI; config written safely and reversibly |
| **M6** | Packaging | Desktop-extension bundle for Claude Desktop; documented manual path for everything else |
| **M7** | Proof pack | Clean-room connect on each supported client, screenshots, transcripts answering real questions |
| **M8** | Remote (conditional on §3) | User-owned tunnel, per-client revocable tokens, live indicator, scoped consent |

## 8. Acceptance criteria

1. A user with ReMynd installed connects Claude Desktop in one click and gets a correct answer to
   "what was I doing yesterday afternoon" with no terminal use.
2. The server answers correctly with ReMynd **not running**.
3. Retrieval accuracy matches the shipped CLI on the same questions, graded against independent SQL.
4. Loopback HTTP rejects a request with a foreign `Origin` (403) and refuses to bind 0.0.0.0.
5. No runtime dependency beyond what macOS ships and what is inside the app bundle.
6. Read-only throughout; a write attempt is refused by SQLite itself.
7. Disconnect removes every config entry it added and leaves the file valid.
8. A fresh install with no recordings connects cleanly and reports honestly that there is nothing yet.

## 9. Risks

| Risk | Mitigation |
|---|---|
| Remote endpoint weakens the privacy claim | Local-only v1; remote is opt-in, user-owned, separately consented, visibly indicated |
| Non-coding agents call tools badly | M3 is a dedicated description-quality milestone graded against ground truth, not an afterthought |
| Tool result sizes blow up context | Reuse the budget governor; MCP results are capped and say what they truncated |
| Client config formats drift | Config writing is one module with per-client adapters and a backup/restore path |
| Two front-ends drift apart | M1 extracts the core first, deliberately, so there is one implementation |
| `app.db` schema is now a contract for a second consumer | Already true of the CLI; note it in the schema docs rather than discovering it twice |

## 10. Open questions

1. **Remote at all?** Ship local-only and tell ChatGPT users it is unsupported, or build the
   user-owned tunnel and adjust the claim? This is the decision that shapes the rest.
2. **Where does the shared core live?** A Swift package inside the app that the CLI shells into, or
   the shell core staying canonical with Swift calling it? The first is cleaner; the second keeps the
   shipped, tested implementation untouched.
3. **Default scope for non-coding agents.** The coding sync sends full OCR body text after opt-in.
   Is that the right default for an assistant that texts over iMessage, or should verbatim text be a
   second consent there?
4. **Does the MCP server supersede the Claude Code hooks?** Push-per-prompt is genuinely better for
   that client, but maintaining both is a cost. Proposal: keep both, hooks stay default for Claude
   Code.
5. **iMessage specifically.** Which bridge are we targeting? If it runs on the same Mac, stdio works
   today and no tunnel is needed — that would make the flagship personal-agent case a local one.
