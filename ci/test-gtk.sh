#!/usr/bin/env bash
set -euo pipefail

swift_args=()
if [[ -n "${THEIA_SWIFT_SCRATCH_PATH:-}" ]]; then
    swift_args+=(--scratch-path "$THEIA_SWIFT_SCRATCH_PATH")
fi
swift test "${swift_args[@]}" -j "${THEIA_SWIFT_JOBS:-2}"
bin_path=$(swift build "${swift_args[@]}" --show-bin-path)
fixture=Tests/TheiaGTKTests/Fixtures/uint8_simple.fits
ci/smoke-gtk.sh "$bin_path/theia-gtk" "$fixture"
ci/smoke-gtk-http.sh "$bin_path/theia-gtk" "$fixture"
ci/smoke-gtk-xpa.sh "$bin_path/theia-gtk" "$fixture"
ci/smoke-gtk-xpa-unix.sh "$bin_path/theia-gtk"
ci/smoke-gtk-multi-instance.sh "$bin_path/theia-gtk" "$fixture"
scripts/test_xpa_local_security.sh "$bin_path"
