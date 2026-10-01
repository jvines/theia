#!/usr/bin/env bash
# The opt-in public XPA mode: with no XPA settings at all, a plain
# `xpaget ds9` reaches Theia the way it reaches DS9; the default private mode
# keeps the same request out.
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

# Public: the same plain request reaches Theia, with no private namespace.
THEIA_XPA=public "$app" "$fits" >"$log" 2>&1 &
app_pid=$!
version=
for _ in $(seq 1 100); do
    version=$(ds9_version)
    [[ "$version" == Theia* ]] && break
    kill -0 "$app_pid" 2>/dev/null || break
    sleep 0.1
done
[[ "$version" == Theia* ]] || { cat "$log" >&2; echo 'public instance did not answer xpaget ds9' >&2; exit 1; }
opened=$(timeout 5 "$bin/xpaget" ds9 file)
[[ "$opened" == "$fits" ]] || { echo "public XPA file is $opened" >&2; exit 1; }
for candidate in "$runtime_root/theia"/instance-"$app_pid"-*/xpans_unix; do
    [[ ! -S "$candidate" ]] || { echo 'public instance also made a private namespace' >&2; exit 1; }
done
timeout 5 "$bin/xpaset" -p ds9 exit
for _ in $(seq 1 100); do
    kill -0 "$app_pid" 2>/dev/null || break
    sleep 0.1
done
if kill -0 "$app_pid" 2>/dev/null; then
    cat "$log" >&2
    echo 'public instance did not quit after xpaset exit' >&2
    exit 1
fi
wait "$app_pid" || true
app_pid=
echo 'GTK public XPA smoke: PASS'
