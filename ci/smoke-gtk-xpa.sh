#!/usr/bin/env bash
set -euo pipefail

app=${1:?usage: smoke-gtk-xpa.sh APP FITS_FILE}
fits=$(realpath "${2:?usage: smoke-gtk-xpa.sh APP FITS_FILE}")
log=$(mktemp)
app_pid=
cleanup() {
    if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
        kill "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
    rm -- "$log"
}
trap cleanup EXIT

export PATH="$(dirname "$app"):$PATH"
export XPA_METHOD=inet
ns_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
export XPA_NSINET="127.0.0.1:$ns_port"
"$app" >"$log" 2>&1 &
app_pid=$!

version=
for _ in $(seq 1 50); do
    version=$(timeout 3 xpaget ds9 version 2>/dev/null || true)
    [[ "$version" == Theia* ]] && break
    kill -0 "$app_pid" 2>/dev/null || break
    sleep 0.1
done
if [[ "$version" != Theia* ]]; then
    cat "$log" >&2
    echo 'GTK XPA version request failed' >&2
    exit 1
fi

timeout 5 xpaset -p ds9 file "$fits" || { cat "$log" >&2; exit 1; }
opened=$(timeout 5 xpaget ds9 file)
[[ "$opened" == "$fits" ]] || { echo "XPA opened wrong file: $opened" >&2; exit 1; }
timeout 5 xpaset -p ds9 scale log || { cat "$log" >&2; exit 1; }
stretch=$(timeout 5 xpaget ds9 scale)
[[ "$stretch" == log ]] || { echo "XPA scale is $stretch" >&2; exit 1; }
frame=$(timeout 5 xpaget ds9 frame)
[[ "$frame" == 1 ]] || { echo "XPA frame is $frame" >&2; exit 1; }
timeout 5 xpaset -p ds9 cmap HEAT || { cat "$log" >&2; exit 1; }
cmap=$(timeout 5 xpaget ds9 cmap)
[[ "$cmap" == heat ]] || { echo "XPA cmap is $cmap" >&2; exit 1; }
if reply=$(timeout 5 xpaset -p ds9 cmap bogus 2>&1); then
    echo 'XPA accepted an unknown colour map' >&2
    exit 1
fi
[[ "$reply" == *"valid: "*heat* ]] || { echo "XPA cmap error lacks the valid names: $reply" >&2; exit 1; }
contrast=$(timeout 5 xpaget ds9 zscale contrast)
[[ "$contrast" == 0.25 ]] || { echo "XPA zscale contrast is $contrast" >&2; exit 1; }
printf 'image; circle(10,10,3)' | timeout 5 xpaset ds9 regions || { cat "$log" >&2; exit 1; }
timeout 5 xpaset -p ds9 regions command '{box 5 5 4 4 0}' || { cat "$log" >&2; exit 1; }
regions=$(timeout 5 xpaget ds9 regions)
[[ "$regions" == *"circle(10, 10, 3)"* && "$regions" == *"box(5, 5, 4, 4, 0)"* ]] ||
    { echo "XPA regions are: $regions" >&2; exit 1; }
timeout 5 xpaset -p ds9 regions delete || { cat "$log" >&2; exit 1; }
regions=$(timeout 5 xpaget ds9 regions)
[[ "$regions" != *"("* ]] || { echo "XPA regions delete left: $regions" >&2; exit 1; }

timeout 5 xpaset -p ds9 exit || { cat "$log" >&2; exit 1; }
for _ in $(seq 1 100); do
    if ! kill -0 "$app_pid" 2>/dev/null; then break; fi
    sleep 0.1
done
if kill -0 "$app_pid" 2>/dev/null; then
    cat "$log" >&2
    echo 'GTK app did not quit after XPA exit' >&2
    exit 1
fi
wait "$app_pid"
app_pid=
echo 'GTK XPA smoke: PASS'
