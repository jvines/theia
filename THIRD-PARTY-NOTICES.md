# Third-Party Notices

This project is licensed under the [BSD 3-Clause License](LICENSE). It vendors
CFITSIO and XPA under `Sources/` and bundles a separate FFmpeg executable in the
Linux package. Each component retains its own license.

## CFITSIO — `Sources/CFITSIO`

FITS file I/O library by William Pence, High Energy Astrophysics Science Archive
Research Center (HEASARC), NASA Goddard Space Flight Center. Vendored version:
4.6.4.

A U.S. Government work: no copyright is claimed in the United States under Title
17, U.S. Code, with an explicit grant to freely use, copy, modify, and distribute
the software and its documentation, provided the copyright notice and disclaimer
of warranty are retained. Permissive; compatible with redistribution here.

Full text: [`Sources/CFITSIO/License.txt`](Sources/CFITSIO/License.txt) (reproduced
from the `fitsio.h` header).

CFITSIO aggregates several independently-copyrighted components, all redistributed
by HEASARC under the CFITSIO umbrella license above:
- Hcompress / Rice compression — Copyright (c) 1993 Association of Universities for
  Research in Astronomy (AURA), STScI (`fits_hcompress.c`, `fits_hdecompress.c`).
- `iraffits.c` — IRAF-format reader, Smithsonian Astrophysical Observatory.
- PLIO mask compression — NOAO / IRAF.
- `group.c` grouping conventions — ISDC / University of Geneva.
- LZW (`.Z`) decompression — public-domain `compress` lineage.
- `eval_y.c` / `eval_tab.h` — GNU Bison-generated parser. The embedded GPL text is
  accompanied by the standard Bison "special exception," which permits distributing
  the (unmodified) parser skeleton under terms of your choice — hence BSD-compatible.

## XPA — `Sources/CXPA` (and the `xpans` / `xpaget` / `xpaset` executables)

Messaging/IPC system used for the DS9-compatible scripting interface, by the
Smithsonian Astrophysical Observatory.

Copyright (c) 2014–2016 Smithsonian Institution. Licensed under the **MIT License**.

Full text: [`Sources/CXPA/XPA-LICENSE.txt`](Sources/CXPA/XPA-LICENSE.txt).

## FFmpeg and libx264 — Linux package

The Linux package contains a separate static FFmpeg 9.0 executable with libx264
enabled. It is copied from `mwader/static-ffmpeg:9.0`, pinned to multi-architecture
image digest `sha256:b90574a4e2ae62b763c39c384526689e7eb435da6398f4fb3f6c3f1c6a14ce33`.
Theia invokes this executable for H.264 MP4 export; it does not link against it.
That build reports `--enable-gpl`, `--enable-version3`, and `--enable-libx264`.
FFmpeg in the Linux package is distributed under GPLv3; the license text is at
[`resources/linux/GPL-3.0.txt`](resources/linux/GPL-3.0.txt).

Build scripts and component source references are at
[`wader/static-ffmpeg`](https://github.com/wader/static-ffmpeg).
FFmpeg source is at [ffmpeg.org](https://ffmpeg.org/download.html), and x264
source is at [VideoLAN](https://www.videolan.org/developers/x264.html).

## DejaVu fonts — Linux package

The Linux package contains DejaVu Sans and Sans Bold for systems
without installed fonts. Their license is reproduced in the package as
`share/doc/theia/DejaVu-LICENSE`.
