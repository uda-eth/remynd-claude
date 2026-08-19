#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# MCP conformance suite.
#
# Claude Desktop and Claude Code are verified by using them. This exists for
# the clients that are not installed here — Cursor, Gemini CLI, Codex, ChatGPT
# — where "the config file was written" is a much weaker claim than "the client
# can actually drive it".
#
# So it drives the server the way those clients do: every protocol revision
# they might negotiate, the exact handshake order, the bare environment a GUI
# app hands a subprocess, and the config schema each one expects. It cannot
# prove a client works, but every failure it catches is one a client would
# have hit.
#
#   tests/mcp-conformance.sh
# ---------------------------------------------------------------------------
set -uo pipefail

MCP="${REMYND_MCP:-$HOME/.remynd-sync/bin/remynd-mcp}"
pass=0; fail=0
ok()  { printf '  \033[1;32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[1;31m✗ %s\033[0m\n' "$*"; fail=$((fail+1)); }
hd()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

[ -x "$MCP" ] || { echo "no server at $MCP"; exit 1; }
echo "server: $MCP ($("$MCP" --version))"

# Send a sequence of JSON-RPC lines, return stdout.
drive() { printf '%s\n' "$@" | "$MCP" 2>/dev/null; }

# ---------------------------------------------------------------------------
hd "Protocol revisions a client might negotiate"
# Clients in the wild are spread across revisions. Refusing one a client speaks
# means it never gets past initialize — a total failure, not a degraded one.
for V in 2024-11-05 2025-03-26 2025-06-18 2025-11-25 2026-07-28; do
  R="$(drive "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"$V\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}")"
  got="$(printf '%s' "$R" | /usr/bin/python3 -c 'import json,sys
try:
    o=json.loads(sys.stdin.readline())
    print(o["result"]["protocolVersion"])
except Exception: print("ERR")' 2>/dev/null)"
  if [ "$got" = "ERR" ] || [ -z "$got" ]; then
    bad "initialize($V) produced no usable result"
  else
    ok "initialize($V) → $got"
  fi
done

# ---------------------------------------------------------------------------
hd "Handshake order, as clients actually send it"
OUT="$(drive \
  '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')"
LINES="$(printf '%s' "$OUT" | grep -c .)"
[ "$LINES" = "2" ] && ok "notification draws no reply (2 responses for 3 messages)" \
                   || bad "expected 2 responses, got $LINES"

N="$(printf '%s' "$OUT" | tail -1 | /usr/bin/python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]["tools"]))' 2>/dev/null)"
[ "${N:-0}" -ge 6 ] && ok "tools/list returns $N tools" || bad "tools/list returned ${N:-none}"

# Every tool needs a name, a description and a schema, or a client cannot
# render it and a model cannot choose it.
BADT="$(printf '%s' "$OUT" | tail -1 | /usr/bin/python3 -c '
import json,sys
bad=[]
for t in json.load(sys.stdin)["result"]["tools"]:
    if not t.get("name"): bad.append("unnamed")
    if len(t.get("description","")) < 60: bad.append(t.get("name","?")+":thin-description")
    s=t.get("inputSchema")
    if not isinstance(s,dict) or s.get("type")!="object": bad.append(t.get("name","?")+":bad-schema")
print(",".join(bad) if bad else "")' 2>/dev/null)"
[ -z "$BADT" ] && ok "every tool has a name, a real description and an object schema" \
               || bad "tool definition problems: $BADT"

# ---------------------------------------------------------------------------
hd "Methods a client calls whether or not you support them"
for M in ping tools/list resources/list prompts/list; do
  R="$(drive "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"$M\"}")"
  printf '%s' "$R" | grep -q '"result"' && ok "$M answers with a result" \
                                        || bad "$M did not return a result"
done
R="$(drive '{"jsonrpc":"2.0","id":9,"method":"totally/unknown"}')"
printf '%s' "$R" | grep -q '"code":-32601' && ok "unknown method → -32601, not silence" \
                                           || bad "unknown method mishandled"

# ---------------------------------------------------------------------------
hd "Bad input does not take the server down"
# A client that sends one malformed frame must not lose the session.
OUT="$(drive 'not json at all' '{"jsonrpc":"2.0","id":1,"method":"ping"}')"
printf '%s' "$OUT" | grep -q '"code":-32700' && ok "garbage line → parse error" || bad "no parse error"
printf '%s' "$OUT" | tail -1 | grep -q '"result"' && ok "session survives a malformed frame" \
                                                  || bad "server lost the session after bad input"

R="$(drive '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}')"
printf '%s' "$R" | grep -q '"code":-32602' && ok "unknown tool → -32602" || bad "unknown tool mishandled"

# ---------------------------------------------------------------------------
hd "The environment a GUI client actually provides"
# Claude Desktop passes no LANG. Under the C locale the text pipeline could not
# decode multibyte window titles and returned nothing at all — the tools that
# looked broken while working fine from a terminal.
for TOOL in reconstruct_day recent_activity sync_status; do
  ARGS='{}'; [ "$TOOL" = reconstruct_day ] && ARGS="{\"date\":\"$(/bin/date -v-1d '+%Y-%m-%d')\"}"
  R="$(printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$TOOL\",\"arguments\":$ARGS}}" \
       | env -i HOME="$HOME" PATH=/usr/bin:/bin "$MCP" 2>/dev/null)"
  LEN="$(printf '%s' "$R" | /usr/bin/python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)["result"]["content"][0]["text"]))
except Exception: print(0)' 2>/dev/null)"
  [ "${LEN:-0}" -gt 40 ] && ok "$TOOL works with a bare environment (${LEN} chars)" \
                         || bad "$TOOL returned ${LEN:-0} chars under env -i — the LANG class of bug"
done

# ---------------------------------------------------------------------------
hd "Lifecycle: a client holds stdin open and expects the server to stay"
/usr/bin/python3 - "$MCP" <<'PY'
import subprocess, sys, time
p = subprocess.Popen([sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
time.sleep(3)
alive = p.poll() is None
if alive:
    p.stdin.write(b'{"jsonrpc":"2.0","id":1,"method":"ping"}\n'); p.stdin.flush()
    time.sleep(1)
    alive = p.poll() is None
    p.kill()
sys.exit(0 if alive else 1)
PY
[ $? -eq 0 ] && ok "survives an idle session and answers afterwards" \
             || bad "process exits when idle — a client sees 'server disconnected'"

# ---------------------------------------------------------------------------
hd "Result sizes stay inside client limits"
R="$(drive "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"screen_text_in_range\",\"arguments\":{\"from\":\"$(/bin/date -v-2d '+%Y-%m-%d') 08:00\",\"to\":\"$(/bin/date -v-2d '+%Y-%m-%d') 23:59\"}}}")"
LEN="$(printf '%s' "$R" | /usr/bin/python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)["result"]["content"][0]["text"]))
except Exception: print(-1)' 2>/dev/null)"
if [ "${LEN:-0}" -lt 0 ]; then bad "a whole-day text request produced no parseable result"
elif [ "${LEN:-0}" -le 30000 ]; then ok "a whole-day request is capped (${LEN} chars)"
else bad "result is ${LEN} chars — clients reject payloads this size"; fi

# ---------------------------------------------------------------------------
hd "ChatGPT's connector contract"
# ChatGPT will register any MCP server, but its default connector path looks
# for `search` and `fetch` by name and expects a fixed result shape. A server
# with only its own tool names works in developer mode and nowhere else.
NAMES="$(drive '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | tail -1 \
  | /usr/bin/python3 -c 'import json,sys; print(" ".join(t["name"] for t in json.load(sys.stdin)["result"]["tools"]))' 2>/dev/null)"
for T in search fetch; do
  case " $NAMES " in *" $T "*) ok "exposes a tool named $T" ;;
                     *) bad "no $T tool — ChatGPT's default connector path cannot use this server" ;; esac
done

SR="$(drive '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"query":"the"}}}')"
FIRST_ID="$(printf '%s' "$SR" | /usr/bin/python3 -c '
import json,sys
try:
    r=json.load(sys.stdin)["result"]; sc=r["structuredContent"]; rows=sc["results"]
    assert rows, "empty"
    for x in rows:
        for k in ("id","title","url"):
            assert isinstance(x.get(k),str) and x[k], "row missing "+k
    assert json.loads(r["content"][0]["text"])["results"][0]["id"]==rows[0]["id"], "content/structured mismatch"
    print(rows[0]["id"])
except Exception as e:
    print("ERR:"+str(e))' 2>/dev/null)"
case "$FIRST_ID" in
  ERR:*|"") bad "search result shape: ${FIRST_ID:-no result}" ;;
  *) ok "search returns {id,title,url} rows in structuredContent, mirrored in content" ;;
esac

# ChatGPT hands the id back in several forms depending on where it came from.
if [ -n "$FIRST_ID" ] && [ "${FIRST_ID#ERR:}" = "$FIRST_ID" ]; then
  ENC="$(/usr/bin/python3 -c 'import urllib.parse,sys; print(urllib.parse.quote("remynd://moment/"+sys.argv[1], safe=""))' "$FIRST_ID")"
  for FORM in "$FIRST_ID" "remynd://moment/$FIRST_ID" "$ENC"; do
    R="$(drive "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"fetch\",\"arguments\":{\"id\":\"$FORM\"}}}")"
    V="$(printf '%s' "$R" | /usr/bin/python3 -c '
import json,sys
try:
    r=json.load(sys.stdin)["result"]; sc=r["structuredContent"]
    for k in ("id","title","text","url"):
        assert isinstance(sc.get(k),str) and sc[k], "missing "+k
    # Truncating the ENCODED json leaves it unparseable; capping only the
    # encoded copy leaves structuredContent oversized. Both must hold.
    assert json.loads(r["content"][0]["text"])["id"]==sc["id"], "content is not the same object"
    assert len(sc["text"]) <= 24000, "structuredContent.text is %d chars" % len(sc["text"])
    print("ok")
except Exception as e: print("ERR:"+str(e))' 2>/dev/null)"
    LABEL="$(printf '%s' "$FORM" | cut -c1-28)"
    [ "$V" = ok ] && ok "fetch accepts id as '${LABEL}…' and returns a valid capped document" \
                  || bad "fetch('${LABEL}…'): ${V:-no result}"
  done
fi

# ---------------------------------------------------------------------------
hd "Config schemas match what each client documents"
# Verified against the clients' own docs: Gemini CLI reads a top-level
# mcpServers object in ~/.gemini/settings.json; Cursor uses the same shape as
# Claude Desktop in ~/.cursor/mcp.json.
CHK="$(mktemp -d)"
# key and required "type" differ per client — VS Code is the odd one out.
for SPEC in "Claude Desktop:Library/Application Support/Claude/claude_desktop_config.json:mcpServers:" \
            "Cursor:.cursor/mcp.json:mcpServers:" \
            "Gemini CLI:.gemini/settings.json:mcpServers:" \
            "VS Code:Library/Application Support/Code/User/mcp.json:servers:stdio"; do
  NAME="$(printf '%s' "$SPEC" | cut -d: -f1)"
  REL="$(printf '%s' "$SPEC" | cut -d: -f2)"
  KEY="$(printf '%s' "$SPEC" | cut -d: -f3)"
  WANT_TYPE="$(printf '%s' "$SPEC" | cut -d: -f4)"
  H="$CHK/$(echo "$NAME" | tr -d ' ')"; mkdir -p "$H/$(dirname "$REL")"
  echo '{"existing":{"keep":true}}' > "$H/$REL"
  ( cd "$(dirname "${BASH_SOURCE[0]}")/.." && HOME="$H" bash install.sh >/dev/null 2>&1 )
  CMD="$(/usr/bin/sqlite3 :memory: "SELECT json_extract(readfile('$H/$REL'), '\$.$KEY.remynd.command');" 2>/dev/null)"
  KEPT="$(/usr/bin/sqlite3 :memory: "SELECT json_extract(readfile('$H/$REL'), '\$.existing.keep');" 2>/dev/null)"
  ARGS="$(/usr/bin/sqlite3 :memory: "SELECT json_type(readfile('$H/$REL'), '\$.$KEY.remynd.args');" 2>/dev/null)"
  TYPE="$(/usr/bin/sqlite3 :memory: "SELECT COALESCE(json_extract(readfile('$H/$REL'), '\$.$KEY.remynd.type'),'');" 2>/dev/null)"
  if [ -n "$CMD" ] && [ "$ARGS" = "array" ] && [ "$KEPT" = "1" ] && [ "$TYPE" = "$WANT_TYPE" ]; then
    ok "$NAME: $KEY.remynd correct${WANT_TYPE:+ (type=$WANT_TYPE)}, existing keys kept"
  else
    bad "$NAME: command='$CMD' args='$ARGS' kept='$KEPT' type='$TYPE' (wanted '$WANT_TYPE')"
  fi
done
rm -rf "$CHK"

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
