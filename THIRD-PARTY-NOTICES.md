# Third-Party Notices

This project is licensed under the [BSD 3-Clause License](LICENSE). It vendors
CFITSIO and XPA under `Sources/` and bundles a separate FFmpeg executable in the
Linux package. Each component retains its own license.

The Mac and Linux packages also contain three Hubble FITS examples from the
[NASA FITS Support Office](https://fits.gsfc.nasa.gov/fits_samples.html), credited
to NASA/STScI. File-level provenance is in
[`resources/samples/README.md`](resources/samples/README.md).

They also contain a reduced Tau Ceti FEROS spectrum from an ESO observation,
credited to the European Southern Observatory. ESO distributes its archive data
under [CC BY 4.0](https://www.eso.org/cms/eso-data-access-policy.html), which
permits redistribution with credit and preserved FITS headers. File-level
provenance is in [`resources/samples/README.md`](resources/samples/README.md).

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

## Matplotlib colour maps — `Sources/FITSCore/MatplotlibColorMaps.swift`

The inferno, cividis, bone, cool, hot, afmhot, gist_heat, copper, cubehelix,
rainbow and hsv colour maps follow the definitions in matplotlib's
`lib/matplotlib/_cm.py` and `lib/matplotlib/_cm_listed.py`
(https://github.com/matplotlib/matplotlib). cubehelix is D. A. Green's scheme
(2011, Bulletin of the Astronomical Society of India 39, 289) with matplotlib's
default parameters.

Copyright (c) 2012- Matplotlib Development Team; All Rights Reserved.
Distributed under matplotlib's license agreement:

```text
License agreement for matplotlib versions 1.3.0 and later
=========================================================

1. This LICENSE AGREEMENT is between the Matplotlib Development Team
("MDT"), and the Individual or Organization ("Licensee") accessing and
otherwise using matplotlib software in source or binary form and its
associated documentation.

2. Subject to the terms and conditions of this License Agreement, MDT
hereby grants Licensee a nonexclusive, royalty-free, world-wide license
to reproduce, analyze, test, perform and/or display publicly, prepare
derivative works, distribute, and otherwise use matplotlib
alone or in any derivative version, provided, however, that MDT's
License Agreement and MDT's notice of copyright, i.e., "Copyright (c)
2012- Matplotlib Development Team; All Rights Reserved" are retained in
matplotlib  alone or in any derivative version prepared by
Licensee.

3. In the event Licensee prepares a derivative work that is based on or
incorporates matplotlib or any part thereof, and wants to
make the derivative work available to others as provided herein, then
Licensee hereby agrees to include in any such work a brief summary of
the changes made to matplotlib .

4. MDT is making matplotlib available to Licensee on an "AS
IS" basis.  MDT MAKES NO REPRESENTATIONS OR WARRANTIES, EXPRESS OR
IMPLIED.  BY WAY OF EXAMPLE, BUT NOT LIMITATION, MDT MAKES NO AND
DISCLAIMS ANY REPRESENTATION OR WARRANTY OF MERCHANTABILITY OR FITNESS
FOR ANY PARTICULAR PURPOSE OR THAT THE USE OF MATPLOTLIB
WILL NOT INFRINGE ANY THIRD PARTY RIGHTS.

5. MDT SHALL NOT BE LIABLE TO LICENSEE OR ANY OTHER USERS OF MATPLOTLIB
 FOR ANY INCIDENTAL, SPECIAL, OR CONSEQUENTIAL DAMAGES OR
LOSS AS A RESULT OF MODIFYING, DISTRIBUTING, OR OTHERWISE USING
MATPLOTLIB , OR ANY DERIVATIVE THEREOF, EVEN IF ADVISED OF
THE POSSIBILITY THEREOF.

6. This License Agreement will automatically terminate upon a material
breach of its terms and conditions.

7. Nothing in this License Agreement shall be deemed to create any
relationship of agency, partnership, or joint venture between MDT and
Licensee.  This License Agreement does not grant permission to use MDT
trademarks or trade name in a trademark sense to endorse or promote
products or services of Licensee, or any third party.

8. By copying, installing or otherwise using matplotlib ,
Licensee agrees to be bound by the terms and conditions of this License
Agreement.

License agreement for matplotlib versions prior to 1.3.0
========================================================

1. This LICENSE AGREEMENT is between John D. Hunter ("JDH"), and the
Individual or Organization ("Licensee") accessing and otherwise using
matplotlib software in source or binary form and its associated
documentation.

2. Subject to the terms and conditions of this License Agreement, JDH
hereby grants Licensee a nonexclusive, royalty-free, world-wide license
to reproduce, analyze, test, perform and/or display publicly, prepare
derivative works, distribute, and otherwise use matplotlib
alone or in any derivative version, provided, however, that JDH's
License Agreement and JDH's notice of copyright, i.e., "Copyright (c)
2002-2011 John D. Hunter; All Rights Reserved" are retained in
matplotlib  alone or in any derivative version prepared by
Licensee.

3. In the event Licensee prepares a derivative work that is based on or
incorporates matplotlib  or any part thereof, and wants to
make the derivative work available to others as provided herein, then
Licensee hereby agrees to include in any such work a brief summary of
the changes made to matplotlib.

4. JDH is making matplotlib  available to Licensee on an "AS
IS" basis.  JDH MAKES NO REPRESENTATIONS OR WARRANTIES, EXPRESS OR
IMPLIED.  BY WAY OF EXAMPLE, BUT NOT LIMITATION, JDH MAKES NO AND
DISCLAIMS ANY REPRESENTATION OR WARRANTY OF MERCHANTABILITY OR FITNESS
FOR ANY PARTICULAR PURPOSE OR THAT THE USE OF MATPLOTLIB
WILL NOT INFRINGE ANY THIRD PARTY RIGHTS.

5. JDH SHALL NOT BE LIABLE TO LICENSEE OR ANY OTHER USERS OF MATPLOTLIB
 FOR ANY INCIDENTAL, SPECIAL, OR CONSEQUENTIAL DAMAGES OR
LOSS AS A RESULT OF MODIFYING, DISTRIBUTING, OR OTHERWISE USING
MATPLOTLIB , OR ANY DERIVATIVE THEREOF, EVEN IF ADVISED OF
THE POSSIBILITY THEREOF.

6. This License Agreement will automatically terminate upon a material
breach of its terms and conditions.

7. Nothing in this License Agreement shall be deemed to create any
relationship of agency, partnership, or joint venture between JDH and
Licensee.  This License Agreement does not grant permission to use JDH
trademarks or trade name in a trademark sense to endorse or promote
products or services of Licensee, or any third party.

8. By copying, installing or otherwise using matplotlib,
Licensee agrees to be bound by the terms and conditions of this License
Agreement.```

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

The Linux package contains DejaVu Sans, Sans Bold and Sans Mono for
systems without installed fonts. Their license is reproduced in the package as
`share/doc/theia/DejaVu-LICENSE`.
