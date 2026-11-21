#!/usr/bin/env python3
"""Check a debug slideshow's local, per-frame presentation journal."""
import argparse
import json
import math
from collections import Counter
from pathlib import Path
from statistics import median


def summarize(path):
    seen = set()
    gaps = []
    kinds = Counter()
    footprint = []
    first = last = None
    places = years = retained = 0
    for number, line in enumerate(path.read_text().splitlines(), start=1):
        row = json.loads(line)
        if row["sequence"] != number or not row["digest"]:
            raise ValueError(f"Invalid presentation sequence at row {number}.")
        digest = row["digest"]
        if digest in seen:
            raise ValueError(f"A previous asset was displayed again at row {number}.")
        seen.add(digest)
        stamp = float(row["time"])
        if not math.isfinite(stamp) or (last is not None and stamp < last):
            raise ValueError(f"Invalid timestamp at row {number}.")
        if last is None:
            first = stamp
        else:
            gaps.append(stamp - last)
        last = stamp
        if "kind" in row:
            kinds[{0: "photo", 1: "livePhoto", 2: "video"}[row["kind"]]] += 1
            places = max(places, row["places"])
            years = max(years, row["years"])
            retained = max(retained, row["retainedItems"])
        if "footprintBytes" in row:
            footprint.append(row["footprintBytes"])
    if not seen:
        raise ValueError("No displayed media.")
    summary = {"uniqueDisplayed": len(seen), "firstToLastSeconds": round(last - first, 2)}
    if gaps:
        summary.update(medianGapSeconds=round(median(gaps), 2), maxGapSeconds=round(max(gaps), 2))
    if kinds:
        summary.update(mediaKinds=dict(kinds), places=places, years=years, maxRetainedItems=retained)
    if footprint:
        summary.update(footprintSamples=len(footprint), peakSampledFootprintBytes=max(footprint))
    return summary


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("journal", type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(summarize(args.journal), indent=2))
    except (KeyError, OSError, TypeError, ValueError) as error:
        parser.exit(1, f"Verification failed: {error}\n")
