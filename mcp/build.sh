#!/usr/bin/env bash
# Build remynd-mcp as a universal binary.
#
# Every step's exit code is checked, and each slice is built to a fresh path.
# This exists because the ad-hoc version of it did neither: it grepped compiler
# output for "error:" instead of testing $?, so when one slice failed to build
# the stale object from a previous run was still on disk, `lipo` cheerfully
# stitched it to the new one, and the result was a universal binary that ran
# `--version` fine but got SIGKILLed the moment it did real work. It took a
# while to stop suspecting the code.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
SRC=remynd-mcp.swift
OUT=remynd-mcp
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

for slice in arm64 x86_64; do
  echo "  compiling ${slice}"
  if ! xcrun swiftc -O -target "${slice}-apple-macos13.0" "$SRC" -o "$TMP/$slice" 2>"$TMP/${slice}.log"; then
    echo "  BUILD FAILED for $slice:" >&2
    cat "$TMP/${slice}.log" >&2
    exit 1
  fi
  [ -s "$TMP/$slice" ] || { echo "  $slice produced no binary" >&2; exit 1; }
  if grep -q "warning:" "$TMP/${slice}.log"; then
    echo "  warnings in $slice:"; grep "warning:" "$TMP/${slice}.log" | head -5
  fi
done

lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$TMP/universal"
codesign -s - -f "$TMP/universal" 2>/dev/null || true
chmod +x "$TMP/universal"

# Does the universal binary actually SURVIVE?
#
# A lipo-stitched universal binary answered `initialize` over a pipe perfectly
# and was then SIGKILLed a few hundred milliseconds into an idle session with
# stdin held open — which is exactly how a client runs it, and nothing like how
# a smoke test runs it. Claude Desktop reported only "Server disconnected".
# The arm64 slice on its own is fine. So: prefer universal, but prove it lives
# before shipping it, and fall back to the slice that works.
survives() {
  python3 - "$1" <<'PYEOF'
import subprocess, sys, time
p = subprocess.Popen([sys.argv[1]], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
time.sleep(3)
alive = p.poll() is None
if alive:
    p.kill()
sys.exit(0 if alive else 1)
PYEOF
}

if survives "$TMP/universal"; then
  cp "$TMP/universal" "$OUT"
  echo "  universal binary survives an idle session"
else
  cp "$TMP/arm64" "$OUT"
  codesign -s - -f "$OUT" 2>/dev/null || true
  echo "  WARNING: the universal binary is killed when idle; shipping arm64 only."
  echo "           Intel Macs need a separately built x86_64 binary."
fi
chmod +x "$OUT"

# Prove the thing actually speaks the protocol before calling the build done.
# A binary that links is not a binary that works — that was the whole lesson.
reply="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' | ./"$OUT" 2>/dev/null || true)"
if ! printf '%s' "$reply" | grep -q '"serverInfo"'; then
  echo "  SMOKE TEST FAILED — the binary built but does not answer initialize" >&2
  exit 1
fi

echo "  built $(lipo -archs "$OUT") · $(ls -lh "$OUT" | awk '{print $5}') · $(./"$OUT" --version)"
if ! survives "./$OUT"; then
  echo "  SMOKE TEST FAILED — the binary is killed during an idle session" >&2
  exit 1
fi

echo "  smoke test passed (answers initialize, and survives an idle session)"
echo
echo "  To install, replace by rename — never copy over the existing file:"
echo "      cp $OUT ~/.remynd-sync/bin/$OUT.new && mv -f ~/.remynd-sync/bin/$OUT.new ~/.remynd-sync/bin/$OUT"
