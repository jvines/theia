# Bundled FITS samples

The Hubble examples come from the [NASA FITS Support Office sample
collection](https://fits.gsfc.nasa.gov/fits_samples.html), which identifies the
source archive as MAST for most of them. Credit: NASA/STScI.

| File | Example | Original download |
| --- | --- | --- |
| `nicmos_mosaic.fits` | HST NICMOS multi-extension image | https://fits.gsfc.nasa.gov/samples/NICMOSn4hk12010_mos.fits |
| `wfpc2_cube.fits` | HST WFPC2 four-plane image cube | https://fits.gsfc.nasa.gov/samples/WFPC2u5780205r_c0fx.fits |
| `fos_bintable.fits` | HST FOS spectrum with binary table | https://fits.gsfc.nasa.gov/samples/FOSy19g0309t_c2f.fits |

`feros_tau_ceti_20240730.fits` is a reduced Tau Ceti FEROS observation from
Jose's astronomy backup, observed on 2024-07-30 at 06:58:58 UTC. The reduced
FITS file and its header are bundled unchanged (SHA-256:
`c37560cbe83eb13ee8fbd033f07afdb94e3445369d92d9ce0854be3e7665d94c`).
Its cube has 4,096 wavelength pixels, 25 echelle orders, and 11 data planes.
Plane 1 holds wavelength values; select plane 2 in Theia's cube control to see
the extracted flux across the orders. This is an echelle spectrum, not a sky
image. The source exposure is identified as `FEROS.2024-07-30T06:58:58.004` in
the local reduction set.

FEROS observations are held in the [ESO Science Archive](https://www.eso.org/sci/facilities/lasilla/instruments/feros/doc/ImageDB.html).
Credit: European Southern Observatory (ESO). ESO data are distributed under
[CC BY 4.0](https://www.eso.org/cms/eso-data-access-policy.html). The
[archive record][feros-archive-record] lists source dataset
`FEROS.2024-07-30T06:58:58.004`, ESO programme
`60.A-9700(A)`, as publicly released on 2024-07-30 at 07:05:33 UTC. The
reduced file does not contain the raw observation's programme ID.

For a scientific publication using the Hubble observations, follow [MAST's data
attribution guidance](https://archive.stsci.edu/publishing/data-attributions).
For the FEROS observation, follow [ESO's acknowledgement policy](https://www.eso.org/cms/eso-data-access-policy.html).

[feros-archive-record]: https://archive.eso.org/tap_obs/sync?REQUEST=doQuery&LANG=ADQL&FORMAT=csv&QUERY=SELECT+dp_id%2Crelease_date%2Cprog_id%2Cobject+FROM+dbo.raw+WHERE+dp_id%3D%27FEROS.2024-07-30T06%3A58%3A58.004%27
