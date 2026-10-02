#!/usr/bin/env bash
# The opt-in public XPA mode: with no XPA settings at all, a plain
# `xpaget ds9` reaches Theia the way it reaches DS9; the default private mode
# keeps the same request out. theiactl reaches a public instance too.
set -euo pipefail

app=${1:?usage: smoke-gtk-xpa-public.sh APP FITS_FILE}
fits=$(realpath "${2:?usage: smoke-gtk-xpa-public.sh APP FITS_FILE}")
bin=$(dirname "$app")
runtime_root=$(mktemp -d /tmp/theia-xpa-public.XXXXXX)
log=$(mktemp)
app_pid=
# The runtime images have no pgrep.
xpans_pids() {
    for entry in /proc/[0-9]*; do
        [[ "$(cat "$entry/comm" 2>/dev/null)" == xpans ]] && echo "${entry#/proc/}"
    done
    true
}
xpans_before=$(xpans_pids)
stop_app() {
    if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
        kill "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
    app_pid=
}
cleanup() {
    stop_app
    # libxpa leaves the default name server running after the app exits, as
    # with DS9; stop only the one this test started.
    for pid in $(xpans_pids); do
        grep -qx "$pid" <<<"$xpans_before" || kill "$pid" 2>/dev/null || true
    done
    rm -rf -- "$runtime_root"
    rm -f -- "$log"
}
trap cleanup EXIT

export XDG_RUNTIME_DIR="$runtime_root"
unset XPA_METHOD XPA_TMPDIR XPA_NSUNIX XPA_NSINET XPA_NSPORT XPA_PORT THEIA_XPA
ds9_version() { timeout 3 "$bin/xpaget" ds9 version 2>/dev/null || true; }

# Private, the default: a plain xpaget must not reach the instance.
"$app" "$fits" >"$log" 2>&1 &
app_pid=$!
socket=
for _ in $(seq 1 100); do
    for candidate in "$runtime_root/theia"/instance-*/xpans_unix; do
        [[ -S "$candidate" ]] && socket=$candidate
    done
    [[ -n "$socket" ]] && break
    kill -0 "$app_pid" 2>/dev/null || break
    sleep 0.1
done
[[ -n "$socket" ]] || { cat "$log" >&2; echo 'private instance did not start' >&2; exit 1; }
if [[ "$(ds9_version)" == Theia* ]]; then
    echo 'a private instance answered a plain xpaget ds9' >&2
    exit 1
fi
stop_app

# A packaged tree ships theiactl beside the app; a development build uses the
# source copy, which finds xpaget/xpaset on PATH.
theiactl="$bin/theiactl"
[[ -x "$theiactl" ]] || theiactl=$(pwd)/scripts/theiactl
export PATH="$bin:$PATH"
fail() { cat "$log" >&2; echo "$1" >&2; exit 1; }

# Public: the same plain request reaches Theia, with no private namespace, and
# theiactl still lists and drives that one instance. Run with no XPA settings,
# on loopback (XPA_METHOD=localhost, as ergonOS sets it) and on Unix sockets.
public_run() {
    local method=$1 version= opened listing scale
    unset XPA_METHOD XPA_TMPDIR
    [[ "$method" == default ]] || export XPA_METHOD=$method
    if [[ "$method" == unix ]]; then
        export XPA_TMPDIR="$runtime_root/xpa"
        mkdir -p "$XPA_TMPDIR"
    fi
    THEIA_XPA=public "$app" "$fits" >"$log" 2>&1 &
    app_pid=$!
    for _ in $(seq 1 100); do
        version=$(ds9_version)
        [[ "$version" == Theia* ]] && break
        kill -0 "$app_pid" 2>/dev/null || break
        sleep 0.1
    done
    [[ "$version" == Theia* ]] || fail "public instance ($method) did not answer xpaget ds9"
    opened=$(timeout 5 "$bin/xpaget" ds9 file)
    [[ "$opened" == "$fits" ]] || fail "public XPA file ($method) is $opened"
    for candidate in "$runtime_root/theia"/instance-"$app_pid"-*/xpans_unix; do
        [[ ! -S "$candidate" ]] || fail "public instance ($method) also made a private namespace"
    done
    listing=$(timeout 5 "$theiactl" list)
    [[ "$listing" == "$app_pid"$'\t'* && "$(wc -l <<<"$listing")" -eq 1 ]] \
        || fail "theiactl list ($method) did not show the public instance: $listing"
    timeout 5 "$bin/xpaset" -p ds9 scale log
    scale=$(timeout 5 "$theiactl" --instance "$app_pid" get scale </dev/null) \
        || fail "theiactl get ($method) failed on the public instance"
    [[ "$scale" == log ]] || fail "theiactl get scale ($method) is $scale"
    timeout 5 "$theiactl" --instance "$app_pid" set exit </dev/null
    for _ in $(seq 1 100); do
        kill -0 "$app_pid" 2>/dev/null || break
        sleep 0.1
    done
    kill -0 "$app_pid" 2>/dev/null && fail "public instance ($method) did not quit after theiactl set exit"
    wait "$app_pid" || true
    app_pid=
}
public_run default
public_run localhost
public_run unix
echo 'GTK public XPA smoke: PASS'
