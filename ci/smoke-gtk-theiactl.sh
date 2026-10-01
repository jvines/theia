#!/usr/bin/env bash
# Exercise theiactl itself: piped non-tty writes, invocation through a
# symlink in another directory, and cleanup of a stale instance directory
# left behind by a killed process.
set -euo pipefail

app=${1:?usage: smoke-gtk-theiactl.sh APP FITS_FILE}
fits=$(realpath "${2:?usage: smoke-gtk-theiactl.sh APP FITS_FILE}")
# A packaged tree ships theiactl beside the app: run that one with a PATH
# that has no XPA tools, so it must find its own xpaget/xpaset through the
# symlink. A development build uses the source copy and the PATH below.
theiactl="$(dirname "$app")/theiactl"
ctl_env=(env)
if [[ -x "$theiactl" ]]; then
    ctl_env=(env PATH=/usr/bin:/bin)
else
    theiactl=$(pwd)/scripts/theiactl
fi
[[ -x "$theiactl" ]] || { echo "theiactl not found or not executable: $theiactl" >&2; exit 1; }

runtime_root=$(mktemp -d /tmp/theia-theiactl.XXXXXX)
link_dir=$(mktemp -d /tmp/theia-theiactl-link.XXXXXX)
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
    rm -rf -- "$runtime_root" "$link_dir"
    rm -f -- "$log_one" "$log_two"
}
trap cleanup EXIT

export XDG_RUNTIME_DIR="$runtime_root"
unset XPA_METHOD XPA_TMPDIR XPA_NSUNIX XPA_NSINET
export PATH="$(dirname "$app"):$PATH"

# theiactl lives at $link_dir/theiactl, a symlink in a directory that is not
# its own install directory and not scripts/ -- it must still resolve its
# sibling xpaget/xpaset relative to the real file.
ln -s "$theiactl" "$link_dir/theiactl"
ctl="$link_dir/theiactl"

wait_for_instance() {
    local pid=$1 directory=
    for _ in $(seq 1 100); do
        for candidate in "$runtime_root/theia"/instance-"$pid"-*; do
            if [[ -d "$candidate" && -S "$candidate/xpans_unix" ]]; then directory=$candidate; break; fi
        done
        [[ -n "$directory" ]] && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    if [[ -z "$directory" ]]; then
        echo "instance $pid did not start" >&2
        exit 1
    fi
    printf '%s' "$directory"
}

"$app" "$fits" >"$log_one" 2>&1 & first=$!
dir_one=$(wait_for_instance "$first")

listing=$("${ctl_env[@]}" "$ctl" list)
[[ "$(printf '%s\n' "$listing" | wc -l)" -eq 1 ]] || {
    cat "$log_one" >&2
    echo "theiactl list: expected one instance, got: $listing" >&2
    exit 1
}

# A piped, non-tty region write must reach xpaset -- not be dropped by -p.
printf 'image\ncircle(10,10,3)\n' | "${ctl_env[@]}" "$ctl" --instance "$first" set regions
regions=$("${ctl_env[@]}" "$ctl" --instance "$first" get regions </dev/null)
[[ "$regions" == *'circle('* ]] || {
    echo "theiactl get regions did not see the piped write: $regions" >&2
    exit 1
}

# A parameter-only read run from a non-tty context (CI/cron-like) must not
# hang or fail on an empty stdin.
timeout 5 "${ctl_env[@]}" "$ctl" --instance "$first" get version </dev/null >/dev/null

# Start a second instance, SIGKILL it without warning, and confirm
# `theiactl list` both drops it and removes its stale instance directory.
"$app" >"$log_two" 2>&1 & second=$!
dir_two=$(wait_for_instance "$second")
[[ "$(printf '%s\n' "$("${ctl_env[@]}" "$ctl" list)" | wc -l)" -eq 2 ]] || {
    cat "$log_two" >&2
    echo 'theiactl list did not see both instances' >&2
    exit 1
}
second_pid=$second
kill -KILL "$second"
for _ in $(seq 1 100); do
    kill -0 "$second" 2>/dev/null || break
    sleep 0.1
done
kill -0 "$second" 2>/dev/null && { echo 'second instance survived SIGKILL' >&2; exit 1; }
wait "$second" 2>/dev/null || true
second=

after_kill=$("${ctl_env[@]}" "$ctl" list)
[[ "$after_kill" != *"$dir_two"* ]] || {
    echo "theiactl list still shows the killed instance: $after_kill" >&2
    exit 1
}
[[ "$(printf '%s\n' "$after_kill" | wc -l)" -eq 1 ]] || {
    echo "theiactl list did not drop the killed instance cleanly: $after_kill" >&2
    exit 1
}
[[ ! -e "$dir_two" ]] || {
    echo "theiactl list did not clean up the stale instance directory: $dir_two" >&2
    exit 1
}

# --instance against an already-dead PID must fail clearly, not hang.
if "${ctl_env[@]}" "$ctl" --instance "$second_pid" get version </dev/null >"$log_two" 2>&1; then
    echo 'theiactl succeeded against a dead instance' >&2
    exit 1
fi
grep -qi 'not running' "$log_two" || {
    echo "theiactl did not report a clear error for a dead instance: $(cat "$log_two")" >&2
    exit 1
}

timeout 5 "${ctl_env[@]}" "$ctl" --instance "$first" set exit </dev/null
for _ in $(seq 1 100); do
    kill -0 "$first" 2>/dev/null || break
    sleep 0.1
done
if kill -0 "$first" 2>/dev/null; then
    cat "$log_one" >&2
    echo 'GTK app did not quit after theiactl set exit' >&2
    exit 1
fi
wait "$first"
first=
[[ ! -e "$dir_one" ]] || { echo 'GTK left its XPA namespace behind' >&2; exit 1; }

echo 'theiactl smoke: PASS'
