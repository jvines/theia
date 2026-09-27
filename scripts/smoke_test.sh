#!/usr/bin/env bash
# Launch the built Theia app and drive it through the localhost HTTP
# scripting API. Catches the class of failure unit tests can't: crash-on-launch,
# Metal device init failure, broken document-open path, scripting regressions.
#
# Exits non-zero on the first failed assertion and dumps the app log.
#
# Usage: scripts/smoke_test.sh [path-to-Theia-binary]
#   Default binary: .build/debug/Theia

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${1:-$ROOT/.build/debug/Theia}"
BINDIR="$(dirname "$BIN")"
FIXTURE="$ROOT/Tests/FITSCoreTests/Fixtures/uint8_simple.fits"
LOG="$(mktemp -t fitsviewer-smoke.XXXXXX.log)"
APP_PID=""

# Pin a fixed XPA name-server endpoint so the app and our xpaget/xpaset agree on
# the same xpans instance. Must be exported before the app launches.
export XPA_METHOD=inet
export XPA_NSINET=127.0.0.1:14285
export PATH="$BINDIR:$PATH"   # so the app (and we) can find the bundled xpans

fail() {
    echo "SMOKE FAIL: $*" >&2
    echo "----- app log ($LOG) -----" >&2
    cat "$LOG" >&2 || true
    cleanup
    exit 1
}

cleanup() {
    if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        # give it a moment, then hard-kill
        for _ in 1 2 3 4 5; do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.5; done
        kill -9 "$APP_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

[[ -x "$BIN" ]] || fail "binary not found or not executable: $BIN (run 'swift build' first)"
[[ -f "$FIXTURE" ]] || fail "fixture missing: $FIXTURE"

echo "smoke: launching $BIN"
"$BIN" >"$LOG" 2>&1 &
APP_PID=$!

# --- read the per-process port file (max ~20s) ---
TOKEN_FILE="$HOME/Library/Application Support/com.athropa.theia/scripting-token"
PORT_FILE="$(dirname "$TOKEN_FILE")/scripting-port"
PORT=""
for _ in $(seq 1 40); do
    kill -0 "$APP_PID" 2>/dev/null || fail "app exited during startup (pid $APP_PID)"
    if [[ -f "$PORT_FILE" ]]; then
        CANDIDATE_PORT="$(sed -n '1p' "$PORT_FILE")"
        SERVER_PID="$(sed -n '2p' "$PORT_FILE")"
        if [[ "$SERVER_PID" == "$APP_PID" && "$CANDIDATE_PORT" =~ ^[0-9]+$ ]]; then
            PORT="$CANDIDATE_PORT"
            break
        fi
    fi
    sleep 0.5
done
[[ -n "$PORT" ]] || fail "scripting server never wrote its port file: $PORT_FILE"
echo "smoke: server on port $PORT"

# --- read the auth token from the same directory ---
[[ -f "$TOKEN_FILE" ]] || fail "token file not found (looked at: $TOKEN_FILE)"
TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
[[ -n "$TOKEN" ]] || fail "token file empty: $TOKEN_FILE"

BASE="http://127.0.0.1:$PORT"
AUTH=(-H "Authorization: Bearer $TOKEN")

# req METHOD PATH [json-body] -> echoes "HTTP_STATUS<TAB>BODY"
req() {
    local method="$1" path="$2" body="${3:-}"
    if [[ -n "$body" ]]; then
        curl -sS -m 10 -o - -w $'\n%{http_code}' -X "$method" "${AUTH[@]}" \
            -H "Content-Type: application/json" -d "$body" "$BASE$path"
    else
        curl -sS -m 10 -o - -w $'\n%{http_code}' -X "$method" "${AUTH[@]}" "$BASE$path"
    fi
}

assert_status() { # expected actual context
    [[ "$2" == "$1" ]] || fail "$3: expected HTTP $1, got $2"
}

# 1) GET /status (no documents open yet)
OUT="$(req GET /status)"; CODE="${OUT##*$'\n'}"; BODY="${OUT%$'\n'*}"
assert_status 200 "$CODE" "GET /status"
[[ "$BODY" == *'"open"'* ]] || fail "GET /status body missing \"open\": $BODY"
echo "smoke: /status ok"

# 1a) auth must actually be enforced — a tokenless request should be rejected
NOAUTH="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "$BASE/status")"
assert_status 401 "$NOAUTH" "GET /status without token"
echo "smoke: auth enforced (401 without token)"

# 2) POST /open the fixture
OUT="$(req POST /open "{\"path\":\"$FIXTURE\",\"stretch\":\"log\",\"colormap\":\"plasma\",\"vmin\":11,\"vmax\":77}")"; CODE="${OUT##*$'\n'}"; BODY="${OUT%$'\n'*}"
assert_status 200 "$CODE" "POST /open"
[[ "$BODY" == *'"id"'* ]] || fail "POST /open body missing \"id\": $BODY"
echo "smoke: /open ok ($BODY)"

# 3) GET /document/0/info — exercises the document + render model
OUT="$(req GET /document/0/info)"; CODE="${OUT##*$'\n'}"; BODY="${OUT%$'\n'*}"
assert_status 200 "$CODE" "GET /document/0/info"
[[ "$BODY" == *'"stretch"'* && "$BODY" == *'"colormap"'* ]] \
    || fail "GET info body missing expected keys: $BODY"
[[ "$BODY" == *'"stretch":"log"'* && "$BODY" == *'"colormap":"plasma"'* ]] \
    || fail "open-time visual settings were not applied: $BODY"
OUT="$(req POST /document/0/stretch '{"name":"sqrt"}')"; CODE="${OUT##*$'\n'}"
assert_status 200 "$CODE" "POST /document/0/stretch"
OUT="$(req POST /document/0/colormap '{"name":"viridis"}')"; CODE="${OUT##*$'\n'}"
assert_status 200 "$CODE" "POST /document/0/colormap"
OUT="$(req GET /document/0/info)"; BODY="${OUT%$'\n'*}"
[[ "$BODY" == *'"stretch":"sqrt"'* && "$BODY" == *'"colormap":"viridis"'* ]] \
    || fail "immediate visual settings were not applied: $BODY"
OUT="$(req POST /document/0/zscale)"; CODE="${OUT##*$'\n'}"
assert_status 200 "$CODE" "POST /document/0/zscale"
OUT="$(req GET /document/0/info)"; BODY="${OUT%$'\n'*}"
[[ "$BODY" != *'"vmax":77'* ]] || fail "zscale did not reset levels: $BODY"
echo "smoke: /document/0/info ok"

# 4) GET /status should now list the opened file
OUT="$(req GET /status)"; CODE="${OUT##*$'\n'}"; BODY="${OUT%$'\n'*}"
assert_status 200 "$CODE" "GET /status (after open)"
[[ "$BODY" == *"uint8_simple.fits"* ]] || fail "opened file not listed in /status: $BODY"
echo "smoke: opened file listed"

# 4a) open a tile-compressed (.fz) file — exercises the CFITSIO decode path
FZ="$ROOT/Tests/FITSCoreTests/Fixtures/compressed_rice.fits.fz"
if [[ -f "$FZ" ]]; then
    OUT="$(req POST /open "{\"path\":\"$FZ\"}")"; CODE="${OUT##*$'\n'}"; BODY="${OUT%$'\n'*}"
    assert_status 200 "$CODE" "POST /open (.fz)"
    OUT="$(req GET /status)"; BODY="${OUT%$'\n'*}"
    [[ "$BODY" == *"compressed_rice.fits.fz"* ]] || fail ".fz file not listed in /status: $BODY"
    echo "smoke: .fz opened and listed"
else
    echo "smoke: WARNING .fz fixture missing, skipping compressed-open check"
fi

# 4d) HTTP router hygiene (BUG-15/16).
#   BUG-15: an extra 3rd path segment must 404 (not silently match segment 2), and
#   regions/clear must be a real route.
OUT="$(req GET /document/0/info/junk)"; CODE="${OUT##*$'\n'}"
assert_status 404 "$CODE" "GET /document/0/info/junk must 404, not match /info"
OUT="$(req POST /document/0/regions $'image\npoint(1,1)')"; CODE="${OUT##*$'\n'}"
assert_status 200 "$CODE" "POST /document/0/regions"
OUT="$(req GET /document/0/regions)"; CODE="${OUT##*$'\n'}"; BODY="${OUT%$'\n'*}"
assert_status 200 "$CODE" "GET /document/0/regions"
[[ "$BODY" == *'point(1, 1)'* ]] || fail "region POST did not persist in the session: $BODY"
OUT="$(req POST /document/0/regions/clear)"; CODE="${OUT##*$'\n'}"
assert_status 200 "$CODE" "POST /document/0/regions/clear"
OUT="$(req GET /document/0/regions)"; CODE="${OUT##*$'\n'}"; BODY="${OUT%$'\n'*}"
assert_status 200 "$CODE" "GET /document/0/regions after clear"
[[ -z "$BODY" ]] || fail "region clear did not empty the session: $BODY"
echo "smoke: router rejects junk 3rd segment; regions round-trip and clear work"
#   BUG-16: an oversized header arriving complete in one burst must 431 even with a
#   valid token (before the fix the cap was only enforced on incomplete reads).
PAD="$(head -c 20000 /dev/zero | tr '\0' 'A')"
CODE="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "${AUTH[@]}" -H "X-Pad: $PAD" "$BASE/status")"
assert_status 431 "$CODE" "oversized header must be rejected with 431"
echo "smoke: oversized header rejected (431)"

# 4c) a failed scripted open must return an error promptly and leave the app
#     responsive — never block the main thread on a modal alert (BUG-2 regression
#     guard: before the fix the bad open hangs the runloop and this times out).
BADPATH="/no/such/fitsviewer-smoke-missing-$$.fits"
OUT="$(req POST /open "{\"path\":\"$BADPATH\"}")"; CODE="${OUT##*$'\n'}"
assert_status 500 "$CODE" "POST /open (bad path) must fail fast, not hang"
OUT="$(req GET /status)"; CODE="${OUT##*$'\n'}"
assert_status 200 "$CODE" "GET /status after a failed open (app still responsive)"
echo "smoke: failed open returns error without hanging"

# 4b) XPA round-trip — drive the app as if it were DS9 (xpaget/xpaset → app)
if [[ -x "$BINDIR/xpaget" && -x "$BINDIR/xpaset" ]]; then
    XPAGET="$BINDIR/xpaget"; XPASET="$BINDIR/xpaset"
    # version (get)
    XV="$("$XPAGET" ds9 version 2>/dev/null)"
    [[ "$XV" == Theia* ]] || fail "xpaget ds9 version returned: '$XV'"
    # open a file (set) then read it back (get)
    "$XPASET" -p ds9 file "$FIXTURE" 2>/dev/null || fail "xpaset ds9 file failed"
    sleep 1
    XF="$("$XPAGET" ds9 file 2>/dev/null)"
    [[ "$XF" == *"uint8_simple.fits" ]] || fail "xpaget ds9 file returned: '$XF'"
    # set scale, read back
    "$XPASET" -p ds9 scale log 2>/dev/null || fail "xpaset ds9 scale failed"
    XS="$("$XPAGET" ds9 scale 2>/dev/null)"
    [[ "$XS" == "log" ]] || fail "xpaget ds9 scale returned: '$XS' (expected log)"
    # frame (get) must return the active frame number (1-based), not the window count
    XFR="$("$XPAGET" ds9 frame 2>/dev/null)"
    [[ "$XFR" == "1" ]] || fail "xpaget ds9 frame returned: '$XFR' (expected 1)"
    # BUG-8: `scale mode <token>` must map to the real preset and REJECT unknown
    # tokens (previously every mode silently ran zscale yet returned success).
    "$XPASET" -p ds9 scale mode minmax 2>/dev/null || fail "xpaset ds9 scale mode minmax failed"
    if "$XPASET" -p ds9 scale mode bogus 2>/dev/null; then
        fail "xpaset ds9 scale mode bogus succeeded, but unknown scale modes must error"
    fi
    echo "smoke: XPA scale mode maps presets and rejects unknown tokens"
    # unimplemented verbs must NOT be advertised: zoom is no longer a registered
    # access point, so the request fails rather than silently erroring as if supported
    if "$XPAGET" ds9 zoom >/dev/null 2>&1; then
        fail "xpaget ds9 zoom succeeded, but zoom is unimplemented and should not be advertised"
    fi
    echo "smoke: XPA round-trip ok (version/file/scale/frame; dead verbs unadvertised)"
else
    echo "smoke: WARNING xpaget/xpaset not built, skipping XPA round-trip"
fi

# 5) POST /quit and confirm the process exits cleanly
OUT="$(req POST /quit)"; CODE="${OUT##*$'\n'}"
assert_status 200 "$CODE" "POST /quit"
for _ in $(seq 1 20); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.5; done
kill -0 "$APP_PID" 2>/dev/null && fail "app did not exit after /quit"
APP_PID=""
echo "smoke: PASS"
