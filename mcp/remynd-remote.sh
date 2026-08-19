#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# remynd-remote — expose your ReMynd MCP server to agents that cannot run
# locally (ChatGPT, and any assistant that lives off this Mac).
#
# The endpoint runs on YOUR machine and is published through YOUR OWN tunnel on
# YOUR OWN account. ReMynd operates no relay and holds no copy: we are not in
# the path. That is the whole design, and it is also the limit of what we can
# promise — see the wording note at the bottom.
#
#   remynd-remote start     start the endpoint and print the connector URL
#   remynd-remote stop      stop it
#   remynd-remote status    is it live, and where
#   remynd-remote rotate    mint a new token, invalidating the old URL
# ---------------------------------------------------------------------------
set -uo pipefail

SYNC_DIR="${REMYND_STATE_DIR:-$HOME/.remynd-sync}"
REMOTE_DIR="$SYNC_DIR/remote"
MCP_BIN="$SYNC_DIR/bin/remynd-mcp"
PORT="${REMYND_MCP_PORT:-8787}"

mkdir -p "$REMOTE_DIR"
TOKEN_FILE="$REMOTE_DIR/token"
URL_FILE="$REMOTE_DIR/url"
MCP_PID="$REMOTE_DIR/mcp.pid"
TUN_PID="$REMOTE_DIR/tunnel.pid"
TUN_LOG="$REMOTE_DIR/tunnel.log"

say()  { printf '\033[1;36m▸\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

mint_token() {
  # 32 bytes of urandom, hex. Plenty for a bearer token that only ever travels
  # over the tunnel's TLS.
  LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 48
}

alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }

find_tunnel() {
  command -v cloudflared 2>/dev/null && return 0
  for p in /opt/homebrew/bin/cloudflared /usr/local/bin/cloudflared "$REMOTE_DIR/cloudflared"; do
    [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

cmd_start() {
  [ -x "$MCP_BIN" ] || die "remynd-mcp is not installed. Run the ReMynd installer first."

  local token
  if [ -f "$TOKEN_FILE" ]; then token="$(cat "$TOKEN_FILE")"; else
    token="$(mint_token)"; printf '%s' "$token" > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"
  fi

  if alive "$MCP_PID"; then
    ok "Endpoint already running on 127.0.0.1:$PORT"
  else
    "$MCP_BIN" --http --port "$PORT" --token "$token" > "$REMOTE_DIR/mcp.log" 2>&1 &
    echo $! > "$MCP_PID"
    sleep 1
    alive "$MCP_PID" || die "the local endpoint failed to start — see $REMOTE_DIR/mcp.log"
    ok "Local endpoint on 127.0.0.1:$PORT (loopback only)"
  fi

  local cf
  if ! cf="$(find_tunnel)"; then
    warn "No tunnel found, so the endpoint is reachable from this Mac only."
    echo
    echo "  ChatGPT and other off-device agents need a public HTTPS URL. To publish"
    echo "  one on your own Cloudflare account, install cloudflared and re-run:"
    echo
    echo "      brew install cloudflared        # or download from Cloudflare"
    echo "      remynd-remote start"
    echo
    echo "  Locally you can already point any same-machine client at:"
    echo "      http://127.0.0.1:$PORT/mcp    (Authorization: Bearer <token>)"
    return 0
  fi

  if alive "$TUN_PID"; then
    ok "Tunnel already running"
  else
    : > "$TUN_LOG"
    "$cf" tunnel --url "http://127.0.0.1:$PORT" > "$TUN_LOG" 2>&1 &
    echo $! > "$TUN_PID"
    say "Waiting for the tunnel to come up…"
    for _ in $(seq 1 30); do
      grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUN_LOG" 2>/dev/null | head -1 > "$URL_FILE"
      [ -s "$URL_FILE" ] && break
      sleep 1
    done
  fi

  if [ -s "$URL_FILE" ]; then
    local url; url="$(cat "$URL_FILE")"
    echo
    ok "Your connector URL — paste this into ChatGPT or Claude:"
    echo
    echo "    ${url}/mcp?auth=${token}"
    echo
    echo "  This URL is a key to your screen history. Treat it like a password."
    echo "  Revoke it any time with:  remynd-remote rotate"
  else
    warn "Tunnel started but no URL appeared — check $TUN_LOG"
  fi
}

cmd_stop() {
  for f in "$TUN_PID" "$MCP_PID"; do
    if alive "$f"; then kill "$(cat "$f")" 2>/dev/null && ok "Stopped $(basename "$f" .pid)"; fi
    rm -f "$f"
  done
  rm -f "$URL_FILE"
  ok "Remote access is off. Nothing is reachable from outside this Mac."
}

cmd_status() {
  if alive "$MCP_PID"; then ok "Endpoint: running on 127.0.0.1:$PORT"; else echo "  Endpoint: stopped"; fi
  if alive "$TUN_PID"; then
    ok "Tunnel:   running"
    [ -s "$URL_FILE" ] && echo "  URL:      $(cat "$URL_FILE")/mcp?auth=<token>"
  else
    echo "  Tunnel:   stopped — reachable from this Mac only"
  fi
  [ -f "$TOKEN_FILE" ] && echo "  Token:    set ($(wc -c < "$TOKEN_FILE" | tr -d ' ') chars). Rotate to revoke."
}

cmd_rotate() {
  mint_token > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"
  ok "New token minted — every previously shared URL is now dead."
  if alive "$MCP_PID"; then
    say "Restarting the endpoint with the new token…"
    cmd_stop >/dev/null; cmd_start
  fi
}

case "${1:-status}" in
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  rotate) cmd_rotate ;;
  *) echo "usage: remynd-remote {start|stop|status|rotate}"; exit 64 ;;
esac

# ---------------------------------------------------------------------------
# On the wording, because it changes when you turn this on:
#
#   Local only:  "your activity goes to your own agent, and nowhere else."
#   With remote: "your activity goes to your own agent, over your own tunnel,
#                 on your own account. ReMynd runs no relay and keeps no copy."
#
# Both are true. They are not the same sentence, and the second is the one that
# applies the moment a tunnel is live.
# ---------------------------------------------------------------------------
