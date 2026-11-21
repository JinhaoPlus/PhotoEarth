#!/bin/sh
# Capture only the dynamic globe card that accompanies readable journey posters.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
evidence="$repo/.local-test-data/earth-20261119/public-mapkit"
mkdir -p "$evidence"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc -parse-as-library "$repo/Scripts/generate_public_mapkit_shelf.swift" -o "$scratch/capture"

capture() {
    "$scratch/capture" "$1" "$2" "$evidence/$3.png"
}
jpeg() {
    sips --resampleHeightWidth "$2" "$3" --setProperty format jpeg --setProperty formatOptions 90 \
        "$evidence/$1.png" --out "$4" >/dev/null
}

capture 1600 900 globe
jpeg globe 900 1600 "$repo/PhotoEarthTopShelf/EarthShelfGlobe.jpg"
djpeg "$repo/PhotoEarthTopShelf/EarthShelfGlobe.jpg" > "$scratch/globe.ppm"
# Strip input metadata and bound the inline system-card transport.
for quality in 84 80 76 72 68 64 60; do
    cjpeg -optimize -quality "$quality" -outfile "$scratch/preview.jpg" "$scratch/globe.ppm"
    if [ "$(wc -c < "$scratch/preview.jpg")" -le 196608 ]; then break; fi
done
test "$(wc -c < "$scratch/preview.jpg")" -le 196608
cp "$scratch/preview.jpg" "$repo/PhotoEarthTopShelf/EarthShelfGlobePreview.jpg"

design="$repo/Design/TopShelf/MapKit"
mkdir -p "$design"
cp "$evidence/globe.png" "$design/PublicOrbit.png"
cp "$evidence/globe.json" "$design/PublicOrbit.json"
(cd "$repo" && xcrun swift Scripts/verify_public_mapkit_shelf.swift)
