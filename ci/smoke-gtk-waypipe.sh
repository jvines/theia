#!/usr/bin/env bash
set -euo pipefail

app=${1:?usage: smoke-gtk-waypipe.sh APP FITS_FILE}
fits=$(realpath "${2:?usage: smoke-gtk-waypipe.sh APP FITS_FILE}")
runtime=$(mktemp -d)
weston_pid=
client_pid=
server_pid=
cleanup() {
    for pid in "$server_pid" "$client_pid" "$weston_pid"; do
        if [[ -n "$pid" ]]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    rm -r -- "$runtime"
}
trap cleanup EXIT

chmod 700 "$runtime"
export XDG_RUNTIME_DIR="$runtime"
export WAYLAND_DISPLAY=wayland-0
export GDK_BACKEND=wayland
weston --backend=headless-backend.so --use-pixman \
    --socket="$WAYLAND_DISPLAY" --idle-time=0 >"$runtime/weston.log" 2>&1 &
weston_pid=$!
for _ in $(seq 1 100); do
    [[ -S "$runtime/$WAYLAND_DISPLAY" ]] && break
    if ! kill -0 "$weston_pid" 2>/dev/null; then
        cat "$runtime/weston.log" >&2
        exit 1
    fi
    sleep 0.1
done
[[ -S "$runtime/$WAYLAND_DISPLAY" ]] || {
    cat "$runtime/weston.log" >&2
    echo 'headless Wayland compositor did not start' >&2
    exit 1
}

waypipe --no-gpu -s "$runtime/waypipe.sock" client \
    >"$runtime/waypipe-client.log" 2>&1 &
client_pid=$!
for _ in $(seq 1 100); do
    [[ -S "$runtime/waypipe.sock" ]] && break
    if ! kill -0 "$client_pid" 2>/dev/null; then
        cat "$runtime/waypipe-client.log" >&2
        exit 1
    fi
    sleep 0.1
done
[[ -S "$runtime/waypipe.sock" ]] || {
    cat "$runtime/waypipe-client.log" >&2
    echo 'waypipe client did not start' >&2
    exit 1
}

waypipe --no-gpu -s "$runtime/waypipe.sock" server "$app" "$fits" \
    >"$runtime/waypipe-server.log" 2>&1 &
server_pid=$!
instance=
for _ in $(seq 1 100); do
    for candidate in "$runtime/theia"/instance-*/scripting-port; do
        if [[ -f "$candidate" ]]; then instance=$(dirname "$candidate"); break; fi
    done
    [[ -n "$instance" ]] && break
    if ! kill -0 "$server_pid" 2>/dev/null; then
        cat "$runtime/waypipe-server.log" >&2
        cat "$runtime/waypipe-client.log" >&2
        exit 1
    fi
    sleep 0.1
done
[[ -n "$instance" ]] || {
    cat "$runtime/waypipe-server.log" >&2
    echo 'Theia did not start through waypipe' >&2
    exit 1
}

name=$(basename "$instance")
pid=${name#instance-}
pid=${pid%%-*}
for _ in $(seq 1 100); do
    opened=$("$(dirname "$app")/theiactl" --instance "$pid" get file 2>/dev/null || true)
    if [[ "$opened" == "$fits" ]]; then
        echo 'GTK packaged Wayland/waypipe smoke: PASS'
        exit 0
    fi
    sleep 0.1
done
cat "$runtime/waypipe-server.log" >&2
cat "$runtime/waypipe-client.log" >&2
echo 'Theia did not open the FITS file through waypipe' >&2
exit 1
