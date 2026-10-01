# Arch package

The AUR package is named `theia-fits-bin` because `theia-bin` already names the
Eclipse Theia IDE package. It installs this FITS viewer as `theia-fits` and
adjusts the desktop launcher accordingly.

After both architecture archives are published under the same `v<version>`
Forgejo release, generate the recipe from the exact published files:

```sh
python3 scripts/generate_aur_pkgbuild.py \
  --version 0.1.0 \
  --x86-archive dist/Theia-0.1.0-linux-x86_64.tar.xz \
  --arm-archive dist/Theia-0.1.0-linux-aarch64.tar.xz \
  --output /path/to/theia-fits-bin/PKGBUILD
```

Omit `--arm-archive` to generate an `x86_64`-only recipe (no `aarch64` source or
checksum) when only the x86_64 archive has been published yet:

```sh
python3 scripts/generate_aur_pkgbuild.py \
  --version 0.1.0 \
  --x86-archive dist/Theia-0.1.0-linux-x86_64.tar.xz \
  --output /path/to/theia-fits-bin/PKGBUILD
```

In an Arch build environment, run `makepkg --verifysource`, `makepkg`, and
`makepkg --printsrcinfo > .SRCINFO` before publishing the `PKGBUILD` and
`.SRCINFO` to AUR. The recipe requires the archives to have stable release URLs
and checksums, so it is generated from release files rather than using `SKIP`.
