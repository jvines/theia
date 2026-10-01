#!/usr/bin/env python3
"""Assemble an EL8-built Theia executable and its runtime into a relocatable tree."""

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import tarfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
GLIBC_LIBRARIES = {
    "libc.so.6", "libm.so.6", "libpthread.so.0", "libdl.so.2",
    "librt.so.1", "libutil.so.1", "libresolv.so.2",
}
DEPENDENCY = re.compile(r"^\s*(\S+)\s+=>\s+(/\S+)\s+\(")


def run(*command: str) -> None:
    subprocess.run(command, check=True)


def copy_dependencies(source: Path, library_dir: Path) -> None:
    result = subprocess.run(["ldd", str(source)], check=True, capture_output=True, text=True)
    if "not found" in result.stdout:
        raise RuntimeError(f"unresolved dependencies for {source}:\n{result.stdout}")
    for line in result.stdout.splitlines():
        match = DEPENDENCY.match(line)
        if not match:
            continue
        name, resolved = match.groups()
        if name in GLIBC_LIBRARIES:
            continue
        destination = library_dir / name
        if destination.exists():
            continue
        shutil.copy2(Path(resolved).resolve(), destination)


def patch_rpaths(stage: Path, binaries: list[Path], libraries: list[Path]) -> None:
    library_dir = stage / "lib"
    for path in binaries + libraries:
        relative = os.path.relpath(library_dir, path.parent)
        rpath = "$ORIGIN" if relative == "." else f"$ORIGIN/{relative}"
        run("patchelf", "--set-rpath", rpath, str(path))


def assemble(bin_dir: Path, stage: Path, version: str, revision: str) -> None:
    if stage.exists():
        raise FileExistsError(f"package output already exists: {stage}")
    binary_dir = stage / "bin"
    library_dir = stage / "lib"
    binary_dir.mkdir(parents=True)
    library_dir.mkdir()
    binaries = []
    for name in ("theia-gtk", "theia-remote-helper", "xpans", "xpaget", "xpaset"):
        source = bin_dir / name
        if not source.is_file():
            raise FileNotFoundError(source)
        destination = binary_dir / name
        shutil.copy2(source, destination)
        binaries.append(destination)
        copy_dependencies(source, library_dir)

    shutil.copy2(Path("/usr/local/bin/ffmpeg"), binary_dir / "ffmpeg")
    shutil.copy2(ROOT / "scripts/theiactl", binary_dir / "theiactl")
    launcher = binary_dir / "theia"
    launcher.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        # Resolve symlinks first: the AUR package and a PATH shim both
        # install this launcher as a symlink, and an unresolved
        # BASH_SOURCE[0] would put app_dir at the symlink's directory
        # (e.g. /usr) instead of the real install.
        'app_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)\n'
        'export PATH="$app_dir/bin:$PATH"\n'
        'export GSETTINGS_SCHEMA_DIR="$app_dir/share/glib-2.0/schemas"\n'
        'export GIO_EXTRA_MODULES="$app_dir/lib/gio/modules${GIO_EXTRA_MODULES:+:$GIO_EXTRA_MODULES}"\n'
        'export XDG_DATA_DIRS="$app_dir/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"\n'
        'export FONTCONFIG_FILE="$app_dir/share/fontconfig/fonts.conf"\n'
        # The bundled fontconfig was built for /usr/local; resolve the host
        # config's relative includes (conf.d, local.conf) against /etc/fonts.
        'export FONTCONFIG_PATH="${FONTCONFIG_PATH:-/etc/fonts}"\n'
        'export THEIA_LOCALE_DIR="$app_dir/share/locale"\n'
        'exec "$app_dir/bin/theia-gtk" "$@"\n'
    )
    launcher.chmod(0o755)

    modules = []
    for source_dir, target_dir in (
        (Path("/usr/local/lib64/gio/modules"), library_dir / "gio/modules"),
        (Path("/usr/lib64/gio/modules"), library_dir / "gio/modules"),
    ):
        for source in sorted(source_dir.glob("*.so")):
            destination = target_dir / source.name
            if destination.exists():
                continue
            target_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source.resolve(), destination)
            modules.append(destination)
            copy_dependencies(source, library_dir)

    schemas = stage / "share/glib-2.0/schemas"
    shutil.copytree("/usr/local/share/glib-2.0/schemas", schemas)
    locales = stage / "share/locale"
    for source_root in (Path("/usr/local/share/locale"), Path("/usr/share/locale")):
        for source in source_root.glob("*/LC_MESSAGES/*.mo"):
            if source_root != Path("/usr/local/share/locale") and source.stem not in {
                "gtk40", "glib20", "gdk-pixbuf",
            }:
                continue
            destination = locales / source.relative_to(source_root)
            if destination.exists():
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
    if not any(locales.glob("*/LC_MESSAGES/gtk40.mo")):
        raise FileNotFoundError("GTK translation catalogs were not installed in the build image")
    resources = ROOT / "resources/linux"
    applications = stage / "share/applications"
    applications.mkdir(parents=True)
    shutil.copy2(resources / "cl.jvines.theia.desktop", applications)
    icons = stage / "share/icons/hicolor/scalable/apps"
    icons.mkdir(parents=True)
    shutil.copy2(resources / "cl.jvines.theia.svg", icons)
    shutil.copy2(resources / "cl.jvines.theia.desktop", stage)
    shutil.copy2(resources / "cl.jvines.theia.svg", stage)
    (stage / ".DirIcon").symlink_to("cl.jvines.theia.svg")
    app_run = stage / "AppRun"
    app_run.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        'app_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)\n'
        'exec "$app_dir/bin/theia" "$@"\n'
    )
    app_run.chmod(0o755)
    mime_packages = stage / "share/mime/packages"
    mime_packages.mkdir(parents=True)
    shutil.copy2(resources / "cl.jvines.theia.mime.xml", mime_packages)
    run("update-mime-database", str(stage / "share/mime"))

    font_config = stage / "share/fontconfig"
    font_config.mkdir(parents=True)
    shutil.copy2(resources / "fonts.conf", font_config)
    fonts = font_config / "fonts"
    fonts.mkdir()
    for name in ("DejaVuSans.ttf", "DejaVuSans-Bold.ttf", "DejaVuSansMono.ttf"):
        shutil.copy2(Path("/usr/share/fonts/dejavu") / name, fonts)

    licenses = stage / "share/doc/theia"
    licenses.mkdir(parents=True)
    for source in ("LICENSE", "THIRD-PARTY-NOTICES.md", "Sources/CFITSIO/License.txt",
                   "Sources/CXPA/XPA-LICENSE.txt"):
        shutil.copy2(ROOT / source, licenses / Path(source).name)
    shutil.copy2(resources / "GPL-3.0.txt", licenses / "FFmpeg-GPL-3.0.txt")
    shutil.copy2("/usr/share/doc/dejavu-fonts-common/LICENSE", licenses / "DejaVu-LICENSE")

    metadata = stage / "share/theia"
    metadata.mkdir(parents=True)
    shutil.copytree(ROOT / "resources/samples", metadata / "samples")
    swift_version = subprocess.run(
        ["swift", "--version"], check=True, capture_output=True, text=True
    ).stdout.splitlines()[0]
    gtk_version = subprocess.run(
        ["pkg-config", "--modversion", "gtk4"], check=True,
        capture_output=True, text=True
    ).stdout.strip()
    (metadata / "build.json").write_text(json.dumps({
        "schemaVersion": 1,
        "version": version,
        "revision": revision,
        "architecture": platform.machine(),
        "swiftToolchain": swift_version,
        "gtkVersion": gtk_version,
    }, indent=2) + "\n")

    libraries = sorted(library_dir.glob("*.so*"))
    patch_rpaths(stage, binaries, libraries + modules)
    for binary in binaries:
        result = subprocess.run(["ldd", str(binary)], capture_output=True, text=True,
                                check=True, env={**os.environ, "LD_LIBRARY_PATH": str(library_dir)})
        if "not found" in result.stdout:
            raise RuntimeError(f"packaged binary has unresolved libraries: {binary}\n{result.stdout}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", type=Path, required=True)
    parser.add_argument("--stage-dir", type=Path, required=True)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--revision", required=True)
    options = parser.parse_args()
    stage = options.stage_dir.resolve()
    archive = options.archive.resolve() if options.archive else None
    if archive and archive.exists():
        raise FileExistsError(f"package archive already exists: {archive}")
    assemble(options.bin_dir.resolve(), stage, options.version, options.revision)
    if archive:
        archive.parent.mkdir(parents=True, exist_ok=True)
        with tarfile.open(archive, "w:xz") as output:
            output.add(stage, arcname=stage.name)
        print(f"Built {archive}")
    else:
        print(f"Built {stage}")


if __name__ == "__main__":
    main()
