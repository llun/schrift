#!/usr/bin/env bash
# Renders the SVG masters to the app's 1024x1024 asset-catalog PNGs.
# Local macOS design tooling only (Node, Google Chrome, ImageMagick, sips); nothing
# here runs in CI. Set CHROME to use a Chrome binary other than the default.
set -euo pipefail
cd "$(dirname "$0")"
repo="$(git rev-parse --show-toplevel)"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
icons="$repo/Schrift/Assets.xcassets/AppIcon.appiconset"
logo="$repo/Schrift/Assets.xcassets/SchriftLogo.imageset"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

node make-svg.mjs

for variant in light dark tinted; do
  url="$(node -e 'console.log(require("node:url").pathToFileURL(process.argv[1]).href)' "$PWD/schrift-icon-$variant.svg")"
  # Chrome's headless stderr is noise even on success, so check for the file instead.
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --window-size=1024,1024 \
    --screenshot="$tmp/$variant.png" "$url" 2>/dev/null || true
  if [[ ! -s "$tmp/$variant.png" ]]; then
    echo "Chrome did not render schrift-icon-$variant.svg (is CHROME set correctly?)" >&2
    exit 1
  fi
  # Opaque truecolor with no alpha channel (App Store Connect rejects an icon with
  # alpha), then tag it sRGB — the pixels already are; this only names the profile.
  magick "$tmp/$variant.png" -alpha off -colorspace sRGB -strip -define png:color-type=2 "$tmp/$variant-flat.png"
  sips --embedProfile "/System/Library/ColorSync/Profiles/sRGB Profile.icc" "$tmp/$variant-flat.png" >/dev/null
done

cp "$tmp/light-flat.png" "$icons/schrift-app-icon-1024.png"
cp "$tmp/dark-flat.png" "$icons/schrift-app-icon-dark-1024.png"
cp "$tmp/tinted-flat.png" "$icons/schrift-app-icon-tinted-1024.png"
cp "$tmp/light-flat.png" "$logo/schrift-logo-1024.png"
cp "$tmp/dark-flat.png" "$logo/schrift-logo-dark-1024.png"
echo "Exported icon and logo PNGs."
