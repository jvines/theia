#!/usr/bin/env bash
set -euo pipefail

app=$(realpath "${1:?usage: smoke-gtk-native-remote.sh APP FITS_FILE}")
fits=$(realpath "${2:?usage: smoke-gtk-native-remote.sh APP FITS_FILE}")
helper=$(realpath "$(dirname "$app")/theia-remote-helper")
temp=$(mktemp -d)
fixtures=$(mktemp -d)
sshd_pid=
app_pid=
prepared=0
cleanup() {
    if [[ -n "$app_pid" ]]; then
        kill "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
    if [[ -n "$sshd_pid" ]]; then
        kill "$sshd_pid" 2>/dev/null || true
        wait "$sshd_pid" 2>/dev/null || true
    fi
    if [[ "$prepared" == 1 ]]; then
        rm -f /root/.ssh/id_ed25519 /root/.ssh/known_hosts \
            /home/theia-test/.local/bin/theia-remote-helper
    fi
    rm -r -- "$temp"
    rm -r -- "$fixtures"
}
trap cleanup EXIT

chmod 755 "$fixtures"
python3 - "$fixtures" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
def header(cards):
    text = ''.join(card.ljust(80) for card in cards)
    return text.ljust(2880).encode('ascii')
def padded(payload):
    return payload.ljust(2880, b'\0')

cube = header([
    'SIMPLE  =                    T', 'BITPIX  =                    8',
    'NAXIS   =                    3', 'NAXIS1  =                    1',
    'NAXIS2  =                    1', 'NAXIS3  =                    3', 'END',
]) + padded(bytes([2, 3, 5]))
table = header([
    'SIMPLE  =                    T', 'BITPIX  =                    8',
    'NAXIS   =                    0', 'EXTEND  =                    T', 'END',
]) + header([
    "XTENSION= 'BINTABLE'", 'BITPIX  =                    8',
    'NAXIS   =                    2', 'NAXIS1  =                    1',
    'NAXIS2  =                    1', 'PCOUNT  =                    0',
    'GCOUNT  =                    1', 'TFIELDS =                    1',
    "TTYPE1  = 'id'", "TFORM1  = '1B'", 'END',
]) + padded(bytes([42]))
for name, data in [('remote-cube.fits', cube), ('remote-table.fits', table)]:
    path = root / name
    path.write_bytes(data)
    path.chmod(0o644)
PY

# This runs as root only in a disposable runtime container, without host ports.
if [[ -e /root/.ssh/id_ed25519 || -L /root/.ssh/id_ed25519 ||
      -e /root/.ssh/known_hosts || -L /root/.ssh/known_hosts ]] ||
      id -u theia-test >/dev/null 2>&1; then
    echo 'native remote smoke requires a clean disposable runtime container' >&2
    exit 1
fi
prepared=1
ssh-keygen -q -t ed25519 -N '' -f "$temp/client-key"
ssh-keygen -q -t ed25519 -N '' -f "$temp/host-key"
useradd -m -u 1000 -p x -s /bin/bash theia-test
mkdir -p /home/theia-test/.ssh /home/theia-test/.local/bin /root/.ssh
cp "$temp/client-key.pub" /home/theia-test/.ssh/authorized_keys
cp "$temp/client-key" /root/.ssh/id_ed25519
printf '[localhost]:2222 %s\n' "$(cat "$temp/host-key.pub")" > /root/.ssh/known_hosts
printf '#!/bin/sh\nexec "%s" "$@"\n' "$helper" \
    > /home/theia-test/.local/bin/theia-remote-helper
chmod 700 /home/theia-test/.ssh /root/.ssh
chmod 600 /home/theia-test/.ssh/authorized_keys /root/.ssh/id_ed25519 /root/.ssh/known_hosts
chmod 755 /home/theia-test/.local/bin/theia-remote-helper
chown -R theia-test:theia-test /home/theia-test/.ssh /home/theia-test/.local

/usr/sbin/sshd -D -e -p 2222 -h "$temp/host-key" \
    -o PermitRootLogin=no -o PasswordAuthentication=no -o UsePAM=no \
    >"$temp/sshd.log" 2>&1 &
sshd_pid=$!

check_open() {
    local source=$1
    local title="$(basename "$source") — Theia"
    "$app" "ssh://theia-test@localhost:2222$source" >"$temp/app.log" 2>&1 &
    app_pid=$!
    for attempt in $(seq 1 200); do
        if LC_ALL=C.utf8 xwininfo -root -tree | grep -Fq "$title"; then
            printf 'GTK native SSH %s window ready after %d checks\n' "$(basename "$source")" "$attempt"
            kill "$app_pid" 2>/dev/null || true
            wait "$app_pid" 2>/dev/null || true
            app_pid=
            return 0
        fi
        if ! kill -0 "$app_pid" 2>/dev/null; then
            cat "$temp/app.log" >&2
            cat "$temp/sshd.log" >&2
            echo 'GTK app exited before opening the remote file' >&2
            return 1
        fi
        sleep 0.1
    done
    cat "$temp/app.log" >&2
    cat "$temp/sshd.log" >&2
    echo 'GTK remote file window did not appear within 20 seconds' >&2
    return 1
}

check_open "$fits"
check_open "$fixtures/remote-cube.fits"
check_open "$fixtures/remote-table.fits"
