# Security Policy

## Reporting a vulnerability

Please report security issues **privately** rather than opening a public issue.
Email `<SET A SECURITY CONTACT BEFORE PUBLISHING>` with a description and, ideally,
steps to reproduce. You can expect an acknowledgement within a few days.

## Notes on the attack surface

- Theia runs a **localhost-only** HTTP scripting server bound to `127.0.0.1`,
  gated by a per-install bearer token stored `0600` under Application Support. It
  is not reachable from the network.
- It also registers DS9-compatible XPA access points (via the bundled libxpa) for
  local `xpaget` / `xpaset` / pyds9 control.
- Theia opens **untrusted FITS files**, so parser robustness against malformed or
  hostile input is a priority — crashes, hangs, or memory-safety issues on crafted
  files are in scope.

Theia is provided under the BSD 3-Clause License with no warranty (see `LICENSE`).
