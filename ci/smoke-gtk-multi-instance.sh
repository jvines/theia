#!/usr/bin/env bash
# Prove two same-user GTK processes have separate HTTP and XPA connections.
set -euo pipefail

app=${1:?usage: smoke-gtk-multi-instance.sh APP FITS_FILE}
fits=$(realpath "${2:?usage: smoke-gtk-multi-instance.sh APP FITS_FILE}")
runtime_root=$(mktemp -d /tmp/theia-multi.XXXXXX)
log_one=$(mktemp)
log_two=$(mktemp)
first=
second=
cleanup() {
    for pid in "$first" "$second"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    rm -r -- "$runtime_root"
    rm -- "$log_one" "$log_two"
}
trap cleanup EXIT

export XDG_RUNTIME_DIR="$runtime_root"
unset XPA_METHOD XPA_TMPDIR XPA_NSUNIX XPA_NSINET
export PATH="$(dirname "$app"):$PATH"
"$app" >"$log_one" 2>&1 & first=$!
"$app" >"$log_two" 2>&1 & second=$!

wait_for_instance() {
    local pid=$1 directory=
    for _ in $(seq 1 100); do
        for candidate in "$runtime_root/theia"/instance-"$pid"-*; do
            if [[ -d "$candidate" ]]; then directory=$candidate; break; fi
        done
        if [[ -n "$directory" && -f "$directory/scripting-port" &&
              -f "$directory/scripting-token" && -S "$directory/xpans_unix" ]]; then
            printf '%s' "$directory"
            return
        fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    cat "$log_one" "$log_two" >&2
    echo "instance $pid did not start HTTP and XPA" >&2
    exit 1
}

dir_one=$(wait_for_instance "$first")
dir_two=$(wait_for_instance "$second")
[[ "$dir_one" != "$dir_two" ]]
[[ "$(stat -c '%a' "$dir_one")" == 700 ]]
[[ "$(stat -c '%a' "$dir_two")" == 700 ]]
port_one=$(sed -n '1p' "$dir_one/scripting-port")
port_two=$(sed -n '1p' "$dir_two/scripting-port")
[[ "$(sed -n '2p' "$dir_one/scripting-port")" == "$first" ]]
[[ "$(sed -n '2p' "$dir_two/scripting-port")" == "$second" ]]
[[ "$port_one" != "$port_two" ]]
token_one=$(cat "$dir_one/scripting-token")
token_two=$(cat "$dir_two/scripting-token")
[[ "$token_one" != "$token_two" ]]

version_one=$(timeout 5 scripts/theiactl --instance "$first" get version)
version_two=$(timeout 5 scripts/theiactl --instance "$second" get version)
[[ "$version_one" == Theia* && "$version_two" == Theia* ]]
[[ "$(scripts/theiactl list | wc -l)" -eq 2 ]]

base_one="http://127.0.0.1:$port_one"
base_two="http://127.0.0.1:$port_two"
auth_one="Authorization: Bearer $token_one"
auth_two="Authorization: Bearer $token_two"
[[ "$(curl -sS -m 5 -o /dev/null -w '%{http_code}' -H "$auth_one" "$base_two/status")" == 401 ]]
opened=$(curl -sS -m 10 -H "$auth_one" -H 'Content-Type: application/json' \
    -d "{\"path\":\"$fits\"}" "$base_one/open")
[[ "$opened" == *'"id":0'* ]]
other_status=$(curl -sS -m 5 -H "$auth_two" "$base_two/status")
[[ "$other_status" == *'"open":[]'* ]]

for pair in "$port_one:$token_one" "$port_two:$token_two"; do
    port=${pair%%:*}
    token=${pair#*:}
    curl -fsS -m 5 -H "Authorization: Bearer $token" -X POST \
        "http://127.0.0.1:$port/quit" >/dev/null
done
wait "$first"
wait "$second"
first=
second=
[[ ! -e "$dir_one" && ! -e "$dir_two" ]]
echo 'GTK multi-instance scripting smoke: PASS'
