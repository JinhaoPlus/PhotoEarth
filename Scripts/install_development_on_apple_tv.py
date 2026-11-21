#!/usr/bin/env python3
"""Clean-install a signed Photo Earth development build on the selected physical Apple TV."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess

BUNDLE = "com.doupi.PhotoEarth.PhotoEarth"


def device_result(*args):
    output = subprocess.run(
        ["xcrun", "devicectl", "device", *args, "--quiet", "--json-output", "-"],
        check=True, stdout=subprocess.PIPE, text=True,
    )
    return json.loads(output.stdout)["result"]


def installed(device):
    result = device_result("info", "apps", "--device", device, "--bundle-id", BUNDLE)
    return any(app["bundleIdentifier"] == BUNDLE for app in result["apps"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device", help="Apple TV name or UDID")
    parser.add_argument("app", type=Path, help="Already built and signed Debug-appletvos/PhotoEarth.app")
    parser.add_argument("--prepare-for-xcode", action="store_true",
                        help="Verify the build and uninstall the old app. Xcode Run/Test will install the new build.")
    args = parser.parse_args()
    app = args.app.resolve()
    with (app / "Info.plist").open("rb") as file:
        info = plistlib.load(file)
    if info.get("CFBundleIdentifier") != BUNDLE or "AppleTVOS" not in info.get("CFBundleSupportedPlatforms", []):
        parser.error("Select the signed tvOS device build of PhotoEarth.app")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    hardware = device_result("info", "details", "--device", args.device)["hardwareProperties"]
    if hardware["reality"] != "physical" or hardware["platform"] != "tvOS":
        parser.error("The selected destination must be a physical Apple TV")
    device = hardware["udid"]
    if installed(device):
        device_result("uninstall", "app", "--device", device, BUNDLE)
    if installed(device):
        raise SystemExit("The previous Photo Earth installation is still present")
    print("Confirmed that Photo Earth is absent before installation.", flush=True)
    if not args.prepare_for_xcode:
        device_result("install", "app", "--device", device, str(app))
        if not installed(device):
            raise SystemExit("The new Photo Earth installation could not be verified")
        print("Verified the new Photo Earth installation.")


if __name__ == "__main__":
    main()
