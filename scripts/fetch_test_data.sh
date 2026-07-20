#!/usr/bin/env bash
# Fetch real-world FITS files into ./test_data/ for manual + integration testing.
# Files are gitignored; re-run anytime to repair a missing corpus.
#
# Categories:
#   simple_image/      — 2D images with WCS
#   mef/               — multi-extension files
#   tables/            — BINTABLE + ASCII TABLE
#   cubes/             — NAXIS=3 spectral + time-series cubes
#   distortion/        — TAN-SIP / SIP / lookup distortions
#   allsky/            — HEALPix / all-sky projections
#   compressed/        — RICE / GZIP_1 tile-compressed
#
# Primary source: https://fits.gsfc.nasa.gov/fits_samples.html (official NASA FITS
# sample files, public domain). MAST mirrors used where needed.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DATA="$ROOT/test_data"
mkdir -p "$DATA"/{simple_image,mef,tables,cubes,distortion,allsky,compressed}

NASA="https://fits.gsfc.nasa.gov/samples"

# fetch URL DEST_PATH
fetch() {
  local url="$1" dest="$2"
  if [[ -s "$dest" ]]; then
    printf "  ok  %s (cached)\n" "${dest#$DATA/}"
    return 0
  fi
  printf "  --> %s\n" "${dest#$DATA/}"
  if curl --fail --location --silent --show-error --max-time 120 \
          --user-agent "fits_viewer-tests/0.1" -o "$dest.tmp" "$url"; then
    mv "$dest.tmp" "$dest"
  else
    rm -f "$dest.tmp"
    printf "  !!  failed: %s\n" "$url" >&2
    return 1
  fi
}

echo "simple_image/"
fetch "$NASA/FOCx38i0101t_c0f.fits"    "$DATA/simple_image/foc_image.fits"      || true
fetch "$NASA/NICMOSn4hk12010_mos.fits" "$DATA/simple_image/nicmos_mosaic.fits"  || true
fetch "$NASA/EUVEngc4151imgx.fits"     "$DATA/simple_image/euve_ngc4151.fits"   || true
fetch "$NASA/IUElwp25637mxlo.fits"     "$DATA/simple_image/iue_lwp.fits"        || true

echo "mef/"
fetch "$NASA/WFPC2ASSNu5780205bx.fits" "$DATA/mef/wfpc2_assn.fits"  || true
fetch "$NASA/WFPC2u5780205r_c0fx.fits" "$DATA/mef/wfpc2_cube.fits"  || true
fetch "$NASA/FGSf64y0106m_a1f.fits"    "$DATA/mef/fgs_multi.fits"   || true

echo "tables/"
fetch "$NASA/FOSy19g0309t_c2f.fits"    "$DATA/tables/fos_bintable.fits"   || true
fetch "$NASA/HRSz0yd020fm_c2f.fits"    "$DATA/tables/hrs_bintable.fits"   || true
fetch "$NASA/DDTSUVDATA.fits"          "$DATA/tables/ddt_suv.fits"        || true
fetch "$NASA/testkeys.fits"            "$DATA/tables/testkeys.fits"       || true

echo "cubes/"
fetch "$NASA/UITfuv2582gc.fits"        "$DATA/cubes/uit_fuv.fits"   || true
# WFPC2 file is also a 4-plane "cube" (NAXIS=3); already saved above.
cp -f "$DATA/mef/wfpc2_cube.fits" "$DATA/cubes/wfpc2_cube.fits" 2>/dev/null || true

echo "distortion/"
# HST ACS drizzled file with SIP keywords from MAST static sample area.
fetch "https://archive.stsci.edu/pub/hlsp/hcv/acs/jcdma1010_drc.fits" \
      "$DATA/distortion/acs_sip.fits" || true

echo "allsky/"
# WMAP smoothed temperature map (Mollweide-friendly, public domain).
fetch "https://lambda.gsfc.nasa.gov/data/map/dr5/skymaps/9yr/raw/wmap_band_iqumap_r9_9yr_K_v5.fits" \
      "$DATA/allsky/wmap_K_band.fits" || true

echo "compressed/"
# SDSS DR16 RICE-compressed frame (single .fits.bz2 — corona2).
fetch "https://data.sdss.org/sas/dr16/eboss/photoObj/frames/301/3704/3/frame-g-003704-3-0091.fits.bz2" \
      "$DATA/compressed/sdss_frame.fits.bz2" || true
if [[ -s "$DATA/compressed/sdss_frame.fits.bz2" && ! -s "$DATA/compressed/sdss_frame.fits" ]]; then
  bunzip2 -k -f "$DATA/compressed/sdss_frame.fits.bz2" || true
fi

echo
echo "Done. Inventory:"
find "$DATA" -type f -name '*.fits' -o -name '*.fits.bz2' | sort
