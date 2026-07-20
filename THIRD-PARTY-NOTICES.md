# Third-Party Notices

This project (licensed under the [BSD 3-Clause License](LICENSE)) vendors the
following third-party libraries under `Sources/`. Each is redistributed under its
own permissive license, reproduced alongside its source and summarized here. Both
licenses impose only that their copyright and permission notices be retained,
which the vendored license files satisfy.

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
