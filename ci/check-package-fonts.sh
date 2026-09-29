#!/usr/bin/env bash
# Check the packaged fontconfig setup with the fontconfig the package bundles
# and the font environment its launcher exports: host fonts and rules stay in
# effect, current distro rules parse without warnings, and the bundled DejaVu
# faces cover sans-serif and monospace on hosts that have no fonts at all.
set -euo pipefail

stage=$(realpath "${1:?usage: check-package-fonts.sh STAGE}")
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
export XDG_CACHE_HOME=$work/cache
export LD_LIBRARY_PATH=$stage/lib

fail() {
    echo "check-package-fonts: $*" >&2
    exit 1
}

# Run a command under the launcher's own FONTCONFIG_* exports. Any output on
# stderr, beyond fontconfig echoing a requested FC_DEBUG level, means it could
# not parse the configuration cleanly.
packaged() {
    (
        app_dir=$stage
        eval "$(grep '^export FONTCONFIG_' "$stage/bin/theia")"
        "$@"
    ) 2>"$work/stderr"
    ! grep -qv '^FC_DEBUG=[0-9]*$' "$work/stderr" \
        || fail "fontconfig complained: $(cat "$work/stderr")"
}

host_files=$(FONTCONFIG_FILE=/etc/fonts/fonts.conf FONTCONFIG_PATH=/etc/fonts \
    fc-list --format '%{file}\n' | sort -u)
[[ -n "$host_files" ]] || fail 'the build host has no fonts to compare against'
packaged_files=$(packaged fc-list --format '%{file}\n' | sort -u)
hidden=$(comm -23 <(printf '%s\n' "$host_files") <(printf '%s\n' "$packaged_files"))
[[ -z "$hidden" ]] || fail "host fonts hidden by the packaged config:"$'\n'"$hidden"

host_rules=(/etc/fonts/conf.d/*.conf)
[[ -e "${host_rules[0]}" ]] || fail 'the build host has no fontconfig rules to compare against'
loaded=$(packaged env FC_DEBUG=1024 fc-match sans-serif)
for rule in "${host_rules[@]}"; do
    grep -qF "Loading config file from $rule" <<<"$loaded" \
        || fail "host rule not applied by the packaged config: $rule"
done

expect_match() {
    local pattern=$1 family=$2 spacing=$3 found
    shift 3
    found=$(packaged "$@" fc-match --format '%{family[0]}|%{spacing:-0}' "$pattern")
    [[ "${found#*|}" == "$spacing" ]] \
        || fail "$pattern resolved to '${found%|*}' with spacing ${found#*|}, expected $spacing"
    [[ -z "$family" || "${found%|*}" == "$family" ]] \
        || fail "$pattern resolved to '${found%|*}', expected '$family'"
}

# Host fonts available: monospace must still be a fixed-pitch face.
expect_match monospace '' 100

# The packaged config and bundle, with the host include pointed at another
# host's configuration directory instead of this build host's /etc/fonts.
grep -q '<include ignore_missing="yes">/etc/fonts/fonts.conf</include>' \
    "$stage/share/fontconfig/fonts.conf" \
    || fail 'the packaged config does not include the host fontconfig'
rehost() {
    local name=$1 rules=$2
    cp -R "$stage/share/fontconfig" "$work/$name"
    sed -i "s|>/etc/fonts/fonts.conf<|>$rules/fonts.conf<|" "$work/$name/fonts.conf"
}

# A host with newer rules than the build host: Arch's, read by the bundled
# library, must apply without complaint and keep a fixed-pitch monospace.
arch_rules=/opt/fontconfig-rules/arch-2.18.3
[[ -f "$arch_rules/fonts.conf" ]] || fail "$arch_rules is missing from the build image"
rehost arch "$arch_rules"
arch=(env FONTCONFIG_FILE="$work/arch/fonts.conf" FONTCONFIG_PATH="$arch_rules")
arch_loaded=$(packaged "${arch[@]}" env FC_DEBUG=1024 fc-match sans-serif)
for rule in "$arch_rules"/conf.d/*.conf; do
    grep -qF "Loading config file from $rule" <<<"$arch_loaded" \
        || fail "Arch rule not applied by the packaged config: $rule"
done
expect_match monospace '' 100 "${arch[@]}"

# A host without fontconfig: point the host include at nothing and keep the
# bundled directory and fallbacks exactly as packaged.
rehost fontless /nonexistent
fontless=(env FONTCONFIG_FILE="$work/fontless/fonts.conf" FONTCONFIG_PATH=/nonexistent)
bundled=$(packaged "${fontless[@]}" fc-list --format '%{file}\n' | sort -u)
[[ -n "$bundled" ]] && ! grep -qv "^$work/fontless/fonts/" <<<"$bundled" \
    || fail "a font-less host sees fonts outside the bundle:"$'\n'"$bundled"
expect_match sans-serif 'DejaVu Sans' 0 "${fontless[@]}"
expect_match monospace 'DejaVu Sans Mono' 100 "${fontless[@]}"
echo "Packaged fonts: $(wc -l <<<"$packaged_files") visible," \
    "${#host_rules[@]} host rules applied, Arch rules clean, $(wc -l <<<"$bundled") bundled"
