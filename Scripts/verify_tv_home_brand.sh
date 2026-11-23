#!/bin/sh
# Verify the required wide fallback and the app icon in compiled tvOS assets.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
xcrun actool --compile "$scratch" --platform appletvos --minimum-deployment-target 26.0 --target-device tv \
    --app-icon 'App Icon & Top Shelf Image' --output-partial-info-plist "$scratch/partial.plist" \
    --errors --warnings --notices "$repo/PhotoEarth/Assets.xcassets" > "$scratch/actool.log"
xcrun assetutil --info "$scratch/Assets.car" > "$scratch/renditions.json"
python3 - "$scratch" <<'PY'
import json
from pathlib import Path
import plistlib
import sys
root = Path(sys.argv[1])
info = plistlib.loads((root / "partial.plist").read_bytes())
assert info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon") == "App Icon", info
wide = "Top Shelf Image Wide"
assert info.get("TVTopShelfImage") == {"TVTopShelfPrimaryImageWide": wide}, info
renditions = json.loads((root / "renditions.json").read_bytes())
fallbacks = {(r.get("RenditionName"), r.get("PixelWidth"), r.get("PixelHeight"))
             for r in renditions if r.get("Name") == wide}
assert fallbacks == {("EmptyShelf.png", 2320, 720), ("EmptyShelf@2x.png", 4640, 1440)}, fallbacks
assert any(r.get("Name") == "App Icon" and r.get("AssetType") == "ImageStack" for r in renditions)
print("Verified tvOS App Icon and both wide Top Shelf fallback sizes")
PY
