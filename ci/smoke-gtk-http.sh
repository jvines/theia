#!/usr/bin/env bash
set -euo pipefail

app=${1:?usage: smoke-gtk-http.sh APP FITS_FILE}
fits=$(realpath "${2:?usage: smoke-gtk-http.sh APP FITS_FILE}")
runtime_root=$(mktemp -d)
log=$(mktemp)
app_pid=
cleanup() {
    if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
        kill "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
    rm -r -- "$runtime_root"
    rm -- "$log"
}
trap cleanup EXIT

export XDG_RUNTIME_DIR="$runtime_root"
"$app" >"$log" 2>&1 &
app_pid=$!
port_file=
token_file=
port=
instance_dir=
for _ in $(seq 1 100); do
    for candidate in "$runtime_root/theia"/instance-"$app_pid"-*; do
        if [[ -d "$candidate" ]]; then instance_dir=$candidate; break; fi
    done
    if [[ -n "$instance_dir" ]]; then
        port_file="$instance_dir/scripting-port"
        token_file="$instance_dir/scripting-token"
    fi
    if [[ -f "$port_file" && -f "$token_file" ]]; then
        candidate=$(sed -n '1p' "$port_file")
        owner=$(sed -n '2p' "$port_file")
        if [[ "$owner" == "$app_pid" && "$candidate" =~ ^[0-9]+$ ]]; then
            port=$candidate
            break
        fi
    fi
    kill -0 "$app_pid" 2>/dev/null || break
    sleep 0.1
done
if [[ -z "$port" ]]; then
    cat "$log" >&2
    echo 'GTK scripting server did not start' >&2
    exit 1
fi

token=$(tr -d '[:space:]' < "$token_file")
base="http://127.0.0.1:$port"
auth="Authorization: Bearer $token"
status=$(curl -sS -m 5 -H "$auth" "$base/status")
[[ "$status" == *'"open":[]'* ]] || { echo "bad initial status: $status" >&2; exit 1; }
unauthorised=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$base/status")
[[ "$unauthorised" == 401 ]] || { echo "expected 401, got $unauthorised" >&2; exit 1; }

open=$(curl -sS -m 10 -H "$auth" -H 'Content-Type: application/json' \
    -d "{\"path\":\"$fits\",\"colormap\":\"viridis\"}" "$base/open")
[[ "$open" == *'"id":0'* ]] || { echo "bad open response: $open" >&2; exit 1; }
info=$(curl -sS -m 5 -H "$auth" "$base/document/0/info")
[[ "$info" == *'"colormap":"viridis"'* ]] || { echo "bad document info: $info" >&2; exit 1; }

title="$(basename "$fits") — Theia"
for _ in $(seq 1 100); do
    if LC_ALL=C.utf8 xwininfo -root -tree | grep -Fq "$title"; then break; fi
    sleep 0.1
done
LC_ALL=C.utf8 xwininfo -root -tree | grep -Fq "$title" || {
    cat "$log" >&2
    echo 'HTTP open did not create a GTK window' >&2
    exit 1
}

quit=$(curl -sS -m 5 -H "$auth" -X POST "$base/quit")
[[ "$quit" == *'"ok":true'* ]] || { echo "bad quit response: $quit" >&2; exit 1; }
for _ in $(seq 1 100); do
    if ! kill -0 "$app_pid" 2>/dev/null; then break; fi
    sleep 0.1
done
if kill -0 "$app_pid" 2>/dev/null; then
    cat "$log" >&2
    echo 'GTK app did not quit after HTTP response' >&2
    exit 1
fi
wait "$app_pid"
app_pid=
echo 'GTK scripting smoke: PASS'
