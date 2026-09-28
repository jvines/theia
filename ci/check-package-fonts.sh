#!/usr/bin/env bash
# Check the packaged fontconfig setup with the fontconfig the package bundles
# and the font environment its launcher exports: host fonts and rules stay in
# effect, and the bundled DejaVu faces cover sans-serif and monospace on hosts
# that have no fonts at all.
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
# stderr means fontconfig could not parse the configuration cleanly.
packaged() {
    (
        app_dir=$stage
        eval "$(grep '^export FONTCONFIG_' "$stage/bin/theia")"
        "$@"
    ) 2>"$work/stderr"
    [[ ! -s "$work/stderr" ]] || fail "fontconfig complained: $(cat "$work/stderr")"
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

# A host without fontconfig: point the host include at nothing and keep the
# bundled directory and fallbacks exactly as packaged.
cp -R "$stage/share/fontconfig" "$work/fontless"
grep -q '<include ignore_missing="yes">/etc/fonts/fonts.conf</include>' "$work/fontless/fonts.conf" \
    || fail 'the packaged config does not include the host fontconfig'
sed -i 's|>/etc/fonts/fonts.conf<|>/nonexistent/fonts.conf<|' "$work/fontless/fonts.conf"
fontless=(env FONTCONFIG_FILE="$work/fontless/fonts.conf" FONTCONFIG_PATH=/nonexistent)
bundled=$(packaged "${fontless[@]}" fc-list --format '%{file}\n' | sort -u)
[[ -n "$bundled" ]] && ! grep -qv "^$work/fontless/fonts/" <<<"$bundled" \
    || fail "a font-less host sees fonts outside the bundle:"$'\n'"$bundled"
expect_match sans-serif 'DejaVu Sans' 0 "${fontless[@]}"
expect_match monospace 'DejaVu Sans Mono' 100 "${fontless[@]}"
echo "Packaged fonts: $(wc -l <<<"$packaged_files") visible," \
    "${#host_rules[@]} host rules applied, $(wc -l <<<"$bundled") bundled"
