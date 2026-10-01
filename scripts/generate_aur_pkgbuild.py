#!/usr/bin/env python3
"""Fill the AUR recipe with hashes of the two published Linux archives."""

import argparse
import hashlib
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def archive_hash(path: Path, version: str, architecture: str) -> str:
    expected_name = f"Theia-{version}-linux-{architecture}.tar.xz"
    if path.name != expected_name:
        raise ValueError(f"expected {expected_name}, got {path.name}")
    digest = hashlib.sha256()
    with path.open("rb") as archive:
        for block in iter(lambda: archive.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--x86-archive", type=Path, required=True)
    parser.add_argument(
        "--arm-archive", type=Path,
        help="omit to generate an x86_64-only recipe",
    )
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", options.version):
        parser.error("version must be a numeric major.minor.patch release")
    if options.output.exists():
        parser.error(f"output already exists: {options.output}")
    replacements = {
        "@VERSION@": options.version,
        "@X86_SHA256@": archive_hash(options.x86_archive, options.version, "x86_64"),
    }
    recipe = (ROOT / "packaging/aur/PKGBUILD.in").read_text()
    if options.arm_archive is not None:
        replacements["@ARM_SHA256@"] = archive_hash(
            options.arm_archive, options.version, "aarch64"
        )
    else:
        recipe = recipe.replace("arch=('x86_64' 'aarch64')", "arch=('x86_64')")
        recipe = re.sub(r"\nsource_aarch64=.*", "", recipe)
        recipe = re.sub(r"\nsha256sums_aarch64=.*", "", recipe)
    for marker, value in replacements.items():
        recipe = recipe.replace(marker, value)
    if re.search(r"@[A-Z0-9_]+@", recipe):
        raise RuntimeError("AUR recipe contains an unfilled template marker")
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(recipe)
    print(f"Built {options.output}")


if __name__ == "__main__":
    main()
