"""Stage an exported fixture only in an explicitly named isolated tvOS simulator."""
import argparse
import collections
import datetime
import json
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("device")
parser.add_argument("source", type=Path)
parser.add_argument("--manifest", default="manifest.json")
parser.add_argument("--per-year", type=int)
args = parser.parse_args()
def sim(*cmd, capture=True):
    return subprocess.run(["xcrun", "simctl", *cmd], check=True, capture_output=capture, text=True).stdout
devices = json.loads(sim("list", "devices", "-j"))["devices"]
if not any("tvOS" in runtime and d["udid"] == args.device and d["state"] == "Booted" and
           d["name"].startswith("Photo Earth · 真实图库") for runtime, sims in devices.items() for d in sims):
    parser.error("Choose a booted private fixture simulator")
bundle = "local.photoearth.FixtureImport"
docs = Path(sim("get_app_container", args.device, bundle, "data").strip()) / "Documents"
directory = docs / "sample"
directory.mkdir(exist_ok=True, parents=True)
epoch = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)
items = []
counts = collections.Counter()
for row in json.loads((args.source / args.manifest).read_text()):
    year = (epoch + datetime.timedelta(seconds=row["date"])).year
    if args.per_year and counts[year] >= args.per_year:
        continue
    for filename in row["files"]:
        if Path(filename).name != filename or not filename:
            raise ValueError("Invalid fixture resource name")
        source, dest = args.source / filename, directory / filename
        if not dest.exists() or dest.stat().st_size != source.stat().st_size:
            temp = dest.with_suffix(dest.suffix + ".partial")
            shutil.copyfile(source, temp)
            temp.replace(dest)
        if dest.stat().st_size != source.stat().st_size:
            raise OSError("Incomplete fixture resource")
    items.append(row)
    counts[year] += 1
temp = directory / "manifest.partial"
temp.write_text(json.dumps(items))
temp.replace(directory / "manifest.json")
(docs / "fixture-simulator").write_text(args.device)
sim("privacy", args.device, "grant", "photos", bundle)
sim("launch", "--terminate-running-process", args.device, bundle)
print(f"Staged {len(items)} assets. Year counts: {dict(sorted(counts.items()))}")
print(f"Readback: {docs / 'import-summary.json'}")
