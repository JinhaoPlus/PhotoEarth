"""Install five public synthetic media into the isolated Scan Gates Apple TV.
Run before JourneyScanScopeUITests. Needs Python Pillow, Xcode and a booted simulator.
"""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time

from PIL import Image

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("udid")
args = parser.parse_args()
def command(*args):
    return subprocess.check_output(args, text=True).strip()
def sim(*args):
    return command("xcrun", "simctl", *args)
devices = json.loads(sim("list", "devices", "-j"))["devices"]
if not any(d["udid"] == args.udid and d["name"] == "Photo Earth · Scan Gates" and d["state"] == "Booted"
           for runtime, entries in devices.items() if "tvOS" in runtime for d in entries):
    raise SystemExit("Select the dedicated, booted Photo Earth · Scan Gates simulator.")
bundle = "local.photoearth.ScanScopeSeed"
source = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory() as temp:
    app = Path(temp) / "ScanScopeSeed.app"
    app.mkdir()
    sdk = command("xcrun", "--sdk", "appletvsimulator", "--show-sdk-path")
    command("xcrun", "swiftc", "-sdk", sdk, "-target", "arm64-apple-tvos26.0-simulator",
            "-parse-as-library", str(source / "Import.swift"), str(source / "Sample.swift"), "-o", str(app / "ScanScopeSeed"))
    with (app / "Info.plist").open("wb") as handle:
        plistlib.dump({"CFBundleExecutable": "ScanScopeSeed", "CFBundleIdentifier": bundle, "CFBundleVersion": "1",
            "CFBundleName": "Scan Scope Seed", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1",
            "MinimumOSVersion": "26.0", "CFBundleSupportedPlatforms": ["AppleTVSimulator"], "UIDeviceFamily": [3],
            "NSPhotoLibraryUsageDescription": "Create a five-photo fixture in this simulator."}, handle)
    command("codesign", "--force", "--sign", "-", str(app))
    sim("install", args.udid, str(app))
docs = Path(sim("get_app_container", args.udid, bundle, "data")) / "Documents"
sample = docs / "sample"
sample.mkdir(parents=True, exist_ok=True)
(docs / "fixture-simulator").write_text(args.udid)
rows = []
for index, memberships in enumerate([[1], [1, 2], [2], [], []]):
    filename = f"sample-{index}.jpg"
    picture = Image.new("RGB", (640, 360), (30, 40 + index * 35, 210))
    tags = Image.Exif()
    tags[271] = "Synthetic Camera"
    tags[272] = "Scope Test"
    picture.save(sample / filename, exif=tags)
    located = index < 4
    rows.append(dict(key=f"scope{index}", date=800000000 + index * 10, latitude=35.68 if located else None,
                     longitude=139.74 if located else None, favorite=False, kind="photo", screenshot=False,
                     recording=False, files=[filename], albums=memberships))
(sample / "manifest.json").write_text(json.dumps(rows))
progress = docs / "import-summary.json"
progress.unlink(missing_ok=True)
sim("privacy", args.udid, "grant", "photos", bundle)
sim("launch", "--terminate-running-process", args.udid, bundle)
for _ in range(90):
    if progress.exists():
        break
    time.sleep(1)
result = json.loads(progress.read_text())
if result.get("readBack") != 5 or result.get("failed") != 0:
    raise SystemExit(f"Synthetic fixture failed: {result}")
sim("terminate", args.udid, bundle)
print("Five synthetic photos imported, including two overlapping albums and one asset without GPS.")
