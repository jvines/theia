#!/usr/bin/env bash
# Generates dist/AppIcon.icns from the procedural design in make_icon.swift.
# Run this once before packaging; package.sh copies the result into the .app.
set -euo pipefail
cd "$(dirname "$0")/.."

swift scripts/make_icon.swift
iconutil -c icns -o dist/AppIcon.icns dist/AppIcon.iconset
echo "wrote dist/AppIcon.icns"
