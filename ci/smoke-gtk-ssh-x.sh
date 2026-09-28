#!/usr/bin/env bash
set -euo pipefail

app=$(realpath "${1:?usage: smoke-gtk-ssh-x.sh APP FITS_FILE}")
fits=$(realpath "${2:?usage: smoke-gtk-ssh-x.sh APP FITS_FILE}")
temp=$(mktemp -d)
sshd_pid=
cleanup() {
    if [[ -n "$sshd_pid" ]]; then
        kill "$sshd_pid" 2>/dev/null || true
        wait "$sshd_pid" 2>/dev/null || true
    fi
    rm -r -- "$temp"
}
trap cleanup EXIT

# Everything runs inside an ephemeral CI container; sshd has no host port mapping.
ssh-keygen -q -t ed25519 -N '' -f "$temp/client-key"
ssh-keygen -q -t ed25519 -N '' -f "$temp/host-key"
useradd -m -u 1000 -p x -s /bin/bash theia-test
mkdir -p /home/theia-test/.ssh
cp "$temp/client-key.pub" /home/theia-test/.ssh/authorized_keys
chmod 700 /home/theia-test/.ssh
chmod 600 /home/theia-test/.ssh/authorized_keys
chown -R theia-test:theia-test /home/theia-test/.ssh

/usr/sbin/sshd -D -e -p 2222 -h "$temp/host-key" \
    -o X11Forwarding=yes -o X11UseLocalhost=yes \
    -o PermitRootLogin=no -o PasswordAuthentication=no -o UsePAM=no \
    >"$temp/sshd.log" 2>&1 &
sshd_pid=$!

export THEIA_SSH_SMOKE_APP="$app"
export THEIA_SSH_SMOKE_FITS="$fits"
export THEIA_SSH_SMOKE_TEMP="$temp"
xvfb-run -a bash -ec '
    ssh -X -T -i "$THEIA_SSH_SMOKE_TEMP/client-key" -p 2222 \
        -o ForwardX11Trusted=no -o BatchMode=yes -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        theia-test@localhost "$THEIA_SSH_SMOKE_APP" "$THEIA_SSH_SMOKE_FITS" \
        >"$THEIA_SSH_SMOKE_TEMP/app.log" 2>&1 &
    client_pid=$!
    for attempt in $(seq 1 150); do
        if LC_ALL=C.utf8 xwininfo -root -tree |
            grep -Fq "$(basename "$THEIA_SSH_SMOKE_FITS") — Theia"; then
            printf "GTK ssh -X window ready after %d checks\n" "$attempt"
            kill "$client_pid" 2>/dev/null || true
            wait "$client_pid" 2>/dev/null || true
            exit 0
        fi
        if ! kill -0 "$client_pid" 2>/dev/null; then
            cat "$THEIA_SSH_SMOKE_TEMP/app.log" >&2
            cat "$THEIA_SSH_SMOKE_TEMP/sshd.log" >&2
            exit 1
        fi
        sleep 0.1
    done
    cat "$THEIA_SSH_SMOKE_TEMP/app.log" >&2
    echo "GTK window did not appear over ssh -X within 15 seconds" >&2
    exit 1
'
