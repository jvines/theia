#!/usr/bin/env bash
# Keep platform APIs and event loops out of the Linux-compatible Swift targets.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if (( $# > 0 )); then
    targets=("$@")
else
    targets=(Sources/FITSCore Sources/FITSRaster Sources/TheiaKit Sources/XPABridge)
fi

blocked_import='^[[:space:]]*import[[:space:]]+(AppKit|SwiftUI|Combine|Metal|CryptoKit|Network|FoundationNetworking)([[:space:]]|$)'
blocked_api='RunLoop[.]main|Timer[.](scheduledTimer|publish)|[.]perform[(].*afterDelay:|(^|[^[:alnum:]_])Observations([^[:alnum:]_]|$)|[.]runModal[(]'

if find "${targets[@]}" -type f -name '*.swift' -print0 \
    | xargs -0 grep -nE "$blocked_import|$blocked_api"; then
    echo 'Shared Swift targets use a banned platform or event-loop API.' >&2
    exit 1
fi
