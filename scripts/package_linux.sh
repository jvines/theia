#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
config=${CONFIG:-release}
version=$(python3.11 - <<'PY'
from pathlib import Path
import re
source = Path('Sources/TheiaKit/AppVersion.swift').read_text()
print(re.search(r'public static let string = "([^"]+)"', source).group(1))
PY
)
architecture=$(uname -m)
revision=${THEIA_SOURCE_REVISION:-$(git rev-parse HEAD 2>/dev/null || true)}
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || {
    echo 'a full source Git SHA is required for release metadata' >&2
    exit 1
}
distribution=${DIST_DIR:-"$PWD/dist"}
swift_args=(-c "$config")
if [[ -n "${THEIA_SWIFT_SCRATCH_PATH:-}" ]]; then
    swift_args+=(--scratch-path "$THEIA_SWIFT_SCRATCH_PATH")
fi
if [[ -n "${THEIA_PACKAGE_BIN_DIR:-}" ]]; then
    binary_dir=$THEIA_PACKAGE_BIN_DIR
else
    swift build "${swift_args[@]}" -j "${THEIA_SWIFT_JOBS:-2}"
    binary_dir=$(swift build "${swift_args[@]}" --show-bin-path)
fi
name="Theia-${version}-linux-${architecture}"
python3.11 scripts/package_linux.py \
    --bin-dir "$binary_dir" \
    --stage-dir "$distribution/$name" \
    --archive "$distribution/$name.tar.xz" \
    --version "$version" \
    --revision "$revision"
