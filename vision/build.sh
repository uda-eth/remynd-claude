#!/bin/bash
# Rebuild the frame extractor. Needs only the Xcode command line tools.
set -euo pipefail
# An Xcode update leaves its license unaccepted, and every /usr/bin developer
# shim (swiftc, xcrun, python3) then exits 69. The Command Line Tools carry
# their own toolchain and are unaffected, so fall back to them.
if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1 && [ -d /Library/Developer/CommandLineTools ]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
cd "$(dirname "${BASH_SOURCE[0]}")"
OUT="${1:-../bin/remynd-frames}"; mkdir -p "$(dirname "$OUT")"; swiftc -O -o "$OUT" FrameExtract.swift
echo "built: $OUT"
