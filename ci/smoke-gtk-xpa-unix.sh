#!/usr/bin/env bash
# Exercise the actual GTK process's private Unix XPA namespace.
set -euo pipefail

app=${1:?usage: smoke-gtk-xpa-unix.sh APP}
runtime_root=$(mktemp -d /tmp/theia-xpa-app.XXXXXX)
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
unset XPA_METHOD XPA_TMPDIR XPA_NSUNIX XPA_NSINET
export PATH="$(dirname "$app"):$PATH"
"$app" >"$log" 2>&1 &
app_pid=$!

socket=
for _ in $(seq 1 100); do
    socket=$(find "$runtime_root/theia" -maxdepth 2 -type s -name xpans_unix -print -quit 2>/dev/null || true)
    [[ -n "$socket" ]] && break
    kill -0 "$app_pid" 2>/dev/null || break
    sleep 0.1
done
if [[ -z "$socket" ]]; then
    cat "$log" >&2
    echo 'GTK app did not create a private XPA namespace' >&2
    exit 1
fi
instance_dir=$(dirname "$socket")
[[ "$(stat -c '%a' "$instance_dir")" == 700 ]]
[[ "$(stat -c '%u' "$instance_dir")" == "$(id -u)" ]]
[[ "$(find "$instance_dir" -maxdepth 1 -type s | wc -l)" -ge 2 ]]
if runuser -u nobody -- test -x "$instance_dir"; then
    echo 'second uid can traverse the GTK XPA namespace' >&2
    exit 1
fi

export XPA_METHOD=unix
export XPA_TMPDIR="$instance_dir"
export XPA_NSUNIX="$socket"
version=$(timeout 5 xpaget ds9 version)
[[ "$version" == Theia* ]] || { echo "bad private XPA version: $version" >&2; exit 1; }
ctl_version=$(timeout 5 scripts/theiactl --instance "$app_pid" get version)
[[ "$ctl_version" == "$version" ]] || { echo 'theiactl selected the wrong instance' >&2; exit 1; }
if timeout 3 runuser -u nobody -- env \
    XPA_METHOD=unix XPA_TMPDIR="$instance_dir" XPA_NSUNIX="$socket" \
    "$(dirname "$app")/xpaget" ds9 version >/dev/null 2>&1; then
    echo 'second uid queried the GTK XPA namespace' >&2
    exit 1
fi
timeout 5 xpaset -p ds9 exit
for _ in $(seq 1 100); do
    if ! kill -0 "$app_pid" 2>/dev/null; then break; fi
    sleep 0.1
done
if kill -0 "$app_pid" 2>/dev/null; then
    cat "$log" >&2
    echo 'GTK app did not quit after private XPA exit' >&2
    exit 1
fi
wait "$app_pid"
app_pid=
[[ ! -e "$instance_dir" ]] || { echo 'GTK left its XPA namespace behind' >&2; exit 1; }
echo 'GTK private Unix XPA smoke: PASS'
