#!/bin/sh
# Empty dynamic content must not reveal a static Top Shelf from the signed app's assets.
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
assert b"TVTopShelf" not in plistlib.dumps(info), info
renditions = json.loads((root / "renditions.json").read_bytes())
for rendition in renditions:
    for key in ("Name", "RenditionName"):
        name = str(rendition.get(key, "")).lower().replace(" ", "")
        assert "topshelf" not in name and "brandhorizon" not in name, rendition
assert any(r.get("Name") == "App Icon" and r.get("AssetType") == "ImageStack" for r in renditions)
print("tvOS App Icon present; no static Top Shelf rendition or Info.plist registration")
PY
