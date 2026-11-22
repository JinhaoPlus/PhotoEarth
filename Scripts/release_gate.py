#!/usr/bin/env python3
"""Run the PhotoEarth simulator release checks and bind their evidence to an archive."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ["-project", "PhotoEarth.xcodeproj"]
GATE = ROOT / ".local-test-data/release-gate"
RECEIPT = GATE / "passed.json"
SETTINGS = ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION", "PRODUCT_BUNDLE_IDENTIFIER",
            "XCODE_PRODUCT_BUILD_VERSION", "CONFIGURATION")
UI = (
    "PurchaseFlowUITests/testClaimTrialExpireBuyRestoreAndRefund",
    "PurchaseFlowUITests/testTrialExpiresWhileTheAppStaysOpen",
    "LibraryPreparationUITests/testNeutralWelcomeHasNativeFocusAndOpensExplicitSample",
    "LibraryPreparationUITests/testFirstScanCompletesIntoSameGlobeAndSettingsReusesPage",
    "SidebarNavigationTests/testNativeSidebarDestinationsAndCollectionReturn",
    "ExperienceScopeUITests/testCityScopeSurvivesDraggingUntilExplicitCurrentViewSwitch",
    "MapReviewUITests/testHomeCityWallOffersTheSameReviewAndKeepsItsCityScope",
    "ContinuousPhotoViewingTests/testContinuousViewingCrossesPageBoundaryAndReturnsToLastPhoto",
    "EarthSlideshowUITests/testRecentVisitStartsPausesAndReturnsToItsPhotoWall",
    "EarthSlideshowUITests/testFirstOnlineMusicOpenWithoutNetworkCanRetryAndReturnToSlideshow",
    "LocalizationSmokeUITests/testEverySupportedLanguageRendersRemoteActions",
)
# These two Swift Testing probes require private PhotoKit data. Omit them explicitly.
PRIVATE = (
    "PhotoDetailAddressTests/readsCachedDetailsFromAuthorizedLibraryAssets()",
    "PrivateLibrarySimilarityTests/keepsEachDistinctSceneAndSuppressesItsOtherFrameOnAnotherPage()",
)
UNIT_ANCHORS = (
    "JourneyScanGateTests/everyAssetReceivesExactlyOneReasonInPriorityOrder",
    "PhotoWallPaginationTests/denseExcludedFiftyThousandPhotoPageHasAHardCandidateBudget",
    "JourneyShelfTests/shelfMatchesTheHomeDockAndOpensTheSameCityCollection",
)


def output(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def write_json(path, value):
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    temp.replace(path)


def fingerprint():
    digest = hashlib.sha256()
    inputs = (ROOT / "Scripts/release_gate_inputs.xcfilelist").read_text().splitlines()
    for line in inputs:
        path = ROOT / line.removeprefix("$(SRCROOT)/")
        files = sorted(path.rglob("*")) if path.is_dir() else [path]
        for file in files:
            if file.is_dir() or file.name == ".DS_Store":
                continue
            digest.update(str(file.relative_to(ROOT)).encode() + b"\0")
            with file.open("rb") as stream:
                content = hashlib.sha256()
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    content.update(chunk)
            digest.update(content.digest())
    return digest.hexdigest()


def release_settings():
    data = json.loads(output("xcodebuild", *PROJECT, "-target", "PhotoEarth", "-configuration",
                             "Release", "-sdk", "appletvos", "-showBuildSettings", "-json"))
    return {key: data[0]["buildSettings"][key] for key in SETTINGS}


def simulator():
    runtimes = json.loads(output("xcrun", "simctl", "list", "runtimes", "-j"))["runtimes"]
    for runtime in sorted((r for r in runtimes if r["isAvailable"] and r["platform"] == "tvOS"),
                          key=lambda r: tuple(map(int, r["version"].split("."))), reverse=True):
        for device in runtime["supportedDeviceTypes"]:
            if "1080p" in device["identifier"]:
                return runtime, device
    raise ValueError("Install a tvOS Simulator runtime with an Apple TV 1080p device type in Xcode.")


def build(args, log):
    print(f"Running {args[1]} · {log}", flush=True)
    with log.open("w") as stream:
        subprocess.run(args, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, check=True)


def inspect_results(bundle, device_id):
    def report(kind):
        return json.loads(output("xcrun", "xcresulttool", "get", "test-results", kind, "--path", bundle))
    summary = report("summary")
    write_json(bundle.parent / "tests.json", summary)
    if (summary["result"] != "Passed" or summary["failedTests"] or summary["expectedFailures"]
            or summary["skippedTests"] or not summary["passedTests"]):
        raise ValueError("Incomplete or failing tests. See tests.json and Tests.xcresult.")
    tree = report("tests")
    if [d["deviceId"] for d in tree["devices"]] != [device_id]:
        raise ValueError("Unexpected simulator in test results.")
    wanted = set("PhotoEarthUITests/" + case for case in UI)
    wanted.update("PhotoEarthTests/" + case for case in UNIT_ANCHORS)

    def visit(node, target):
        if node["nodeType"] in ("UI test bundle", "Unit test bundle"):
            target = node["name"]
        if node["nodeType"] == "Test Case" and node["result"] == "Passed":
            wanted.discard(target + "/" + node["nodeIdentifier"].removesuffix("()"))
        for child in node.get("children", []):
            visit(child, target)
    for node in tree["testNodes"]:
        visit(node, "")
    if wanted:
        raise ValueError("Missing required tests: " + ", ".join(sorted(wanted)))
    return summary["passedTests"]


def check_archive():
    if not RECEIPT.is_file():
        raise ValueError("Run Scripts/release_gate.py before archiving.")
    receipt = json.loads(RECEIPT.read_text())
    run = GATE / receipt["run"]
    if (receipt["sourceSHA256"] != fingerprint()
            or receipt["settings"] != {k: os.environ[k] for k in SETTINGS}
            or not (run / "Tests.xcresult/Info.plist").is_file()
            or json.loads((run / "report.json").read_text()) != receipt
            or receipt["status"] != "passed"):
        raise ValueError("Archive inputs differ from passing evidence. Run Scripts/release_gate.py.")
    print("PhotoEarth release gate passed:", run)


def run():
    GATE.mkdir(parents=True, exist_ok=True)
    with (GATE / "lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("A PhotoEarth release gate is already running.") from None
        RECEIPT.unlink(missing_ok=True)
        folder = Path(tempfile.mkdtemp(dir=GATE, prefix=datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-")))
        print("Evidence:", folder, flush=True)
        report = {"status": "running", "run": folder.name}
        try:
            report.update(settings=release_settings(), sourceSHA256=fingerprint())
            runtime, device = simulator()
            udid = output("xcrun", "simctl", "create", "PhotoEarth Gate " + folder.name,
                          device["identifier"], runtime["identifier"])
            report.update(simulator=udid, runtime=runtime["identifier"])
            write_json(folder / "report.json", report)
            try:
                with tempfile.TemporaryDirectory(prefix="photoearth-gate-build-") as derived:
                    project = [*PROJECT, "-scheme", "PhotoEarth", "-derivedDataPath", derived]
                    build(["xcodebuild", "build", *project, "-configuration", "Release", "-destination",
                           "generic/platform=tvOS", "CODE_SIGNING_ALLOWED=NO"], folder / "release-build.log")
                    bundle = folder / "Tests.xcresult"
                    try:
                        build(["xcodebuild", "test", *project, "-destination", "platform=tvOS Simulator,id=" + udid,
                               "-parallel-testing-enabled", "NO", "-resultBundlePath", str(bundle),
                               "-only-testing:PhotoEarthTests",
                               *["-skip-testing:PhotoEarthTests/" + case for case in PRIVATE],
                               *["-only-testing:PhotoEarthUITests/" + case for case in UI]], folder / "test.log")
                    finally:
                        if (bundle / "Info.plist").exists():
                            report["passedTests"] = inspect_results(bundle, udid)
            finally:
                subprocess.run(["xcrun", "simctl", "delete", udid], check=True)
            if report["sourceSHA256"] != fingerprint():
                raise ValueError("Release inputs changed during verification. Run the gate again.")
            report["status"] = "passed"
        except BaseException as error:
            report.update(status="failed", error=str(error))
            raise
        finally:
            write_json(folder / "report.json", report)
        write_json(RECEIPT, report)
        print(f"Passed {report['passedTests']} tests. Evidence: {folder}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["run", "doctor", "check-archive"], default="run", nargs="?")
    action = parser.parse_args().action
    try:
        if action == "doctor":
            runtime, device = simulator()
            print(json.dumps(release_settings(), indent=2), runtime["name"], device["name"], sep="\n")
        elif action == "check-archive":
            check_archive()
        else:
            run()
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"error: PhotoEarth release gate: {error}")
