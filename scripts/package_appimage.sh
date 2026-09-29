#!/usr/bin/env bash
set -euo pipefail

stage=${1:?usage: package_appimage.sh STAGE_DIR [OUTPUT.AppImage]}
stage=$(cd "$stage" && pwd)
[[ -x "$stage/AppRun" && -f "$stage/cl.jvines.theia.desktop" ]] || {
    echo 'AppDir is missing AppRun or the desktop entry' >&2
    exit 1
}
architecture=$(uname -m)
# A dated runtime release: upstream republishes "continuous", so its digest moves.
runtime_release=20251108
case "$architecture" in
    x86_64)
        tool_sha=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
        runtime_sha=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d
        ;;
    aarch64)
        tool_sha=f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158
        runtime_sha=00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444
        ;;
    *) echo "unsupported AppImage architecture: $architecture" >&2; exit 1 ;;
esac

output=${2:-"${stage%.AppDir}.AppImage"}
[[ ! -e "$output" ]] || { echo "output already exists: $output" >&2; exit 1; }
tools_dir=${APPIMAGE_TOOL_CACHE:-/tmp/theia-appimage-tools}
mkdir -p "$tools_dir"
tool="$tools_dir/appimagetool-1.9.1-$architecture.AppImage"
runtime="$tools_dir/type2-runtime-$runtime_release-$architecture"
fetch() {
    local url=$1 target=$2 digest=$3
    if [[ ! -f "$target" ]]; then
        curl -fLSs --retry 3 "$url" -o "$target.download"
        mv "$target.download" "$target"
    fi
    printf '%s  %s\n' "$digest" "$target" | sha256sum --check --status || {
        echo "checksum mismatch: $target" >&2
        exit 1
    }
}
fetch "https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-$architecture.AppImage" \
    "$tool" "$tool_sha"
fetch "https://github.com/AppImage/type2-runtime/releases/download/$runtime_release/runtime-$architecture" \
    "$runtime" "$runtime_sha"
chmod +x "$tool"
APPIMAGE_EXTRACT_AND_RUN=1 ARCH="$architecture" "$tool" \
    --runtime-file "$runtime" --no-appstream "$stage" "$output"
echo "Built $output"
