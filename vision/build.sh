#!/bin/bash
# Rebuild the frame extractor. Needs only the Xcode command line tools.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
OUT="${1:-../bin/remynd-frames}"; mkdir -p "$(dirname "$OUT")"; swiftc -O -o "$OUT" FrameExtract.swift
echo "built: $OUT"
