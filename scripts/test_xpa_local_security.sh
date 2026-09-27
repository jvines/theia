#!/usr/bin/env bash
# Run inside the AlmaLinux 8 CI container as root, after swift build.
# A private per-instance XPA directory must stay private after xpans starts.
set -euo pipefail

if [[ "$(id -u)" != 0 ]]; then
    echo "XPA permission test must run as root to probe a second uid" >&2
    exit 1
fi

BIN_DIR="${1:-$(swift build --show-bin-path)}"
[[ -x "$BIN_DIR/xpans" ]] || { echo "xpans binary missing: $BIN_DIR" >&2; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRIVATE_DIR="$(mktemp -d /tmp/theia-xpa-security.XXXXXX)"
PROBE_BIN="$(mktemp /tmp/theia-xpa-probe.XXXXXX)"
XPANS_PID=""
cleanup() {
    if [[ -n "$XPANS_PID" ]] && kill -0 "$XPANS_PID" 2>/dev/null; then
        kill "$XPANS_PID" 2>/dev/null || true
        wait "$XPANS_PID" 2>/dev/null || true
    fi
    rm -r "$PRIVATE_DIR"
    rm -f "$PROBE_BIN"
}
trap cleanup EXIT
cc -std=c11 -Wall -Wextra -Werror -O2 -o "$PROBE_BIN" "$ROOT/scripts/xpa_socket_probe.c"
chmod 755 "$PROBE_BIN"
chmod 700 "$PRIVATE_DIR"

export XPA_METHOD=unix
export XPA_TMPDIR="$PRIVATE_DIR"
export XPA_NSUNIX="$PRIVATE_DIR/xpans_unix"
"$BIN_DIR/xpans" -f "$XPA_NSUNIX" > "$PRIVATE_DIR/xpans.log" 2>&1 &
XPANS_PID=$!

for _ in {1..50}; do
    [[ -S "$XPA_NSUNIX" ]] && break
    kill -0 "$XPANS_PID" 2>/dev/null || { cat "$PRIVATE_DIR/xpans.log" >&2; exit 1; }
    sleep 0.1
done
[[ -S "$XPA_NSUNIX" ]] || { cat "$PRIVATE_DIR/xpans.log" >&2; exit 1; }

DIR_MODE="$(stat -c '%a' "$PRIVATE_DIR")"
[[ "$DIR_MODE" == 700 ]] || {
    echo "XPA changed private directory to mode $DIR_MODE" >&2
    exit 1
}
if runuser -u nobody -- test -x "$PRIVATE_DIR"; then
    echo "second uid can traverse XPA directory" >&2
    exit 1
fi

SOCKET_COUNT=0
for path in "$PRIVATE_DIR"/*; do
    [[ -S "$path" ]] || continue
    SOCKET_COUNT=$((SOCKET_COUNT + 1))
    SOCKET_MODE="$(stat -c '%a' "$path")"
    (( (8#$SOCKET_MODE & 077) == 0 )) || {
        echo "XPA socket $(basename "$path") has mode $SOCKET_MODE" >&2
        exit 1
    }
    if runuser -u nobody -- test -w "$path"; then
        echo "second uid can write XPA socket $(basename "$path")" >&2
        exit 1
    fi
    "$PROBE_BIN" "$path" || {
        echo "same-uid client cannot connect to $(basename "$path")" >&2
        exit 1
    }
    if runuser -u nobody -- "$PROBE_BIN" "$path"; then
        echo "second uid connected to $(basename "$path")" >&2
        exit 1
    fi
done
[[ "$SOCKET_COUNT" -ge 2 ]] || {
    echo "expected xpans name-service and access-point sockets" >&2
    exit 1
}
echo "XPA private directory and $SOCKET_COUNT sockets deny a second uid"
