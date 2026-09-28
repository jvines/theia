#!/usr/bin/env bash
set -euo pipefail

app=${1:?usage: smoke-gtk.sh APP FITS_FILE}
fits=${2:?usage: smoke-gtk.sh APP FITS_FILE}
log=$(mktemp)
app_pid=
cleanup() {
    if [[ -n "$app_pid" ]]; then
        kill "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
    rm -f "$log"
}
trap cleanup EXIT

"$app" "$fits" >"$log" 2>&1 &
app_pid=$!
title="$(basename "$fits") — Theia"
for _ in $(seq 1 100); do
    if LC_ALL=C.utf8 xwininfo -root -tree | grep -Fq "$title"; then
        printf 'GTK window ready: %s\n' "$title"
        exit 0
    fi
    if ! kill -0 "$app_pid" 2>/dev/null; then
        cat "$log" >&2
        echo 'GTK app exited before opening a window' >&2
        exit 1
    fi
    sleep 0.1
done

cat "$log" >&2
echo 'GTK window did not appear within 10 seconds' >&2
exit 1
